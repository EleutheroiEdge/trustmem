#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
resolve_trustmem_paths "${SCRIPT_DIR}"

BACKUP_DIR="${BACKUP_DIR:-${TRUSTMEM_DIR}/vault-backups}"
PROJECT_MAP_FILE="${PROJECT_MAP_FILE:-${TRUSTMEM_DIR}/projects-map.yaml}"
PROMOTED_FILE="${MEM_DIR}/.promoted"

# project_id stamped into generated vault front-matter. Nothing is hard-coded to
# a particular deployment: an explicit env var wins, otherwise scope.project_id
# from the active policy, otherwise the neutral literal "default".
PROJECT_ID_DEFAULT="${TRUSTMEM_PROJECT_ID:-}"
if [[ -z "${PROJECT_ID_DEFAULT}" ]]; then
  PROJECT_ID_DEFAULT="$(policy_project_id "${POLICY_FILE}")"
fi
if [[ -z "${PROJECT_ID_DEFAULT}" ]]; then
  PROJECT_ID_DEFAULT="default"
fi

REBUILD=false
NO_BACKUP=false
for arg in "$@"; do
  case "${arg}" in
    --rebuild) REBUILD=true ;;
    --no-backup) NO_BACKUP=true ;;
    *) echo "vault_sync: unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

if [[ "${NO_BACKUP}" == "true" && "${REBUILD}" != "true" ]]; then
  echo "vault_sync: --no-backup requires --rebuild" >&2
  exit 2
fi

purge_vault_contents() {
  if [[ -z "${VAULT_DIR}" || "${VAULT_DIR}" == "/" || "${VAULT_DIR}" == "${TRUSTMEM_DIR}" || "${VAULT_DIR}" == "${WORKSPACE}" ]]; then
    echo "vault_sync: refusing unsafe vault purge target: ${VAULT_DIR}" >&2
    exit 2
  fi
  if [[ -L "${VAULT_DIR}" ]]; then
    echo "vault_sync: refusing to purge symlinked vault: ${VAULT_DIR}" >&2
    exit 2
  fi
  find "${VAULT_DIR}" -mindepth 1 -depth -delete
}


declare -A PROMOTED_SET
load_promoted() {
  if [[ ! -f "${PROMOTED_FILE}" ]]; then
    return 1
  fi
  while IFS=$'\t' read -r mid _rest; do
    if [[ -n "${mid}" ]]; then
      PROMOTED_SET["${mid}"]=1
    fi
  done < "${PROMOTED_FILE}"
  return 0
}

PROMOTION_AWARE=false
if [[ -f "${PROMOTED_FILE}" ]]; then
  if load_promoted; then
    PROMOTION_AWARE=true
  fi
elif [[ -f "${MEM_DIR}/.promoted_initialized" ]]; then
  echo "vault_sync: ERROR — .promoted manifest was initialized but is now missing." >&2
  echo "vault_sync: This likely means .promoted was accidentally deleted." >&2
  echo "vault_sync: To re-initialize: rm ${MEM_DIR}/.promoted_initialized && trustmem sync --init-promoted" >&2
  exit 2
else
  echo "vault_sync: WARNING — .promoted manifest not found. Processing all lines." >&2
  echo "vault_sync: Run 'trustmem sync --init-promoted' to initialize." >&2
fi


# ── Scope configuration ──────────────────────────────────────────────
# Projects AND people come from projects-map.yaml. The engine ships with no
# built-in project list and no built-in person names: an installation without a
# map simply produces no project or person notes.

declare -A PROJECT_TITLES
declare -A PROJECT_ALIASES
declare -A PERSON_SLUG_BY_ALIAS
declare -A PERSON_TITLE_BY_SLUG
declare -A PERSON_EXCLUDED
PERSON_NAME_PATTERN=""

append_unique_line_var() {
  local var_name="$1"
  local value="$2"
  declare -n ref="${var_name}"
  if [[ -z "${value}" ]]; then
    return
  fi
  if [[ $'\n'"${ref}"$'\n' != *$'\n'"${value}"$'\n'* ]]; then
    if [[ -n "${ref}" ]]; then
      ref+=$'\n'
    fi
    ref+="${value}"
  fi
}

append_unique_assoc() {
  local arr_name="$1"
  local key="$2"
  local value="$3"
  declare -n arr="${arr_name}"
  local existing="${arr[${key}]-}"
  if [[ $'\n'"${existing}"$'\n' != *$'\n'"${value}"$'\n'* ]]; then
    if [[ -n "${existing}" ]]; then
      arr["${key}"]+=$'\n'
    fi
    arr["${key}"]+="${value}"
  fi
}

# Emit TITLE/ALIAS rows for a top-level mapping block ("projects:" or "people:")
# shaped as:
#   <block>:
#     <slug>:
#       name: Display Name
#       aliases:
#         - an alias
parse_scope_block() {
  local block="$1" file="$2"
  if [[ ! -f "${file}" ]]; then
    return
  fi
  awk -v block="${block}" '
    BEGIN { inblock = 0; current = ""; in_aliases = 0 }
    $0 ~ "^" block ":" { inblock = 1; next }
    inblock == 1 {
      if ($0 ~ /^[^[:space:]]/) { inblock = 0; current = ""; in_aliases = 0; next }
      if ($0 ~ /^  [A-Za-z0-9_-]+:/) {
        current = $1
        sub(":", "", current)
        in_aliases = 0
        next
      }
      if (current == "") next
      if ($0 ~ /^    name:[[:space:]]*/) {
        v = $0
        sub(/^    name:[[:space:]]*/, "", v)
        gsub(/"/, "", v)
        print "TITLE\t" current "\t" v
        next
      }
      if ($0 ~ /^    aliases:[[:space:]]*$/) {
        in_aliases = 1
        next
      }
      if (in_aliases == 1 && $0 ~ /^      -[[:space:]]*/) {
        v = $0
        sub(/^      -[[:space:]]*/, "", v)
        gsub(/"/, "", v)
        print "ALIAS\t" current "\t" v
        next
      }
      if (in_aliases == 1 && $0 !~ /^      -[[:space:]]*/) {
        in_aliases = 0
      }
    }
  ' "${file}"
}

# Top-level list block, e.g.
#   people_exclude:
#     - not a person
parse_scope_list() {
  local block="$1" file="$2"
  if [[ ! -f "${file}" ]]; then
    return
  fi
  awk -v block="${block}" '
    BEGIN { inblock = 0 }
    $0 ~ "^" block ":" { inblock = 1; next }
    inblock == 1 {
      if ($0 ~ /^  -[[:space:]]*/) {
        v = $0
        sub(/^  -[[:space:]]*/, "", v)
        gsub(/"/, "", v)
        print v
        next
      }
      inblock = 0
    }
  ' "${file}"
}

load_project_map() {
  local kind slug value
  while IFS=$'\t' read -r kind slug value; do
    if [[ "${kind}" == "TITLE" ]]; then
      PROJECT_TITLES["${slug}"]="${value}"
      append_unique_assoc PROJECT_ALIASES "${slug}" "${slug}"
    elif [[ "${kind}" == "ALIAS" ]]; then
      append_unique_assoc PROJECT_ALIASES "${slug}" "${value}"
    fi
  done < <(parse_scope_block "projects" "${PROJECT_MAP_FILE}")
}

load_people_map() {
  local kind slug value name lowered escaped
  local alternation=""
  while IFS=$'\t' read -r kind slug value; do
    if [[ "${kind}" == "TITLE" ]]; then
      PERSON_TITLE_BY_SLUG["${slug}"]="${value}"
      PERSON_SLUG_BY_ALIAS["${slug,,}"]="${slug}"
      PERSON_SLUG_BY_ALIAS["${value,,}"]="${slug}"
    elif [[ "${kind}" == "ALIAS" ]]; then
      PERSON_SLUG_BY_ALIAS["${value,,}"]="${slug}"
    fi
  done < <(parse_scope_block "people" "${PROJECT_MAP_FILE}")

  while IFS= read -r name; do
    if [[ -n "${name}" ]]; then
      PERSON_EXCLUDED["${name,,}"]=1
    fi
  done < <(parse_scope_list "people_exclude" "${PROJECT_MAP_FILE}")

  # Build one alternation over every configured person alias so bare names can
  # be detected in free text. With no configured people the scan is skipped
  # entirely — the engine never guesses at names.
  for lowered in "${!PERSON_SLUG_BY_ALIAS[@]}"; do
    if [[ -n "${PERSON_EXCLUDED[${lowered}]+_}" ]]; then
      continue
    fi
    escaped="$(regex_escape "${lowered}")"
    if [[ -n "${alternation}" ]]; then
      alternation="${alternation}|"
    fi
    alternation="${alternation}${escaped}"
  done
  if [[ -n "${alternation}" ]]; then
    PERSON_NAME_PATTERN="\\b(${alternation})\\b"
  fi
}

canonical_person_slug() {
  local raw="${1,,}"
  if [[ -n "${PERSON_EXCLUDED[${raw}]+_}" ]]; then
    printf ''
    return
  fi
  if [[ -n "${PERSON_SLUG_BY_ALIAS[${raw}]+_}" ]]; then
    printf '%s' "${PERSON_SLUG_BY_ALIAS[${raw}]}"
    return
  fi
  printf '%s' "$(slugify "${raw}")"
}

canonical_person_title() {
  local raw="${1}"
  local slug
  slug="$(canonical_person_slug "${raw}")"
  if [[ -n "${slug}" && -n "${PERSON_TITLE_BY_SLUG[${slug}]+_}" ]]; then
    printf '%s' "${PERSON_TITLE_BY_SLUG[${slug}]}"
    return
  fi
  printf '%s' "${raw}"
}

project_matches_line() {
  local slug="$1"
  local line="$2"
  local aliases="${PROJECT_ALIASES[${slug}]-}"
  local alias

  if [[ -z "${aliases}" ]]; then
    return 1
  fi

  while IFS= read -r alias; do
    if [[ -n "${alias}" ]] && printf '%s\n' "${line}" | rg -Fqi -- "${alias}"; then
      return 0
    fi
  done <<< "${aliases}"
  return 1
}

write_entity_note() {
  local kind="$1"
  local slug="$2"
  local title="$3"
  local facts="$4"
  local links="$5"
  local mids="${6:-}"
  local singular
  local file="${VAULT_DIR}/${kind}/${slug}.md"
  local today
  today="$(date +%F)"
  case "${kind}" in
    projects) singular="project" ;;
    people) singular="person" ;;
    *) singular="${kind%?}" ;;
  esac

  if [[ -z "${facts}" ]]; then
    facts="- No captured facts yet."
  fi
  if [[ -z "${links}" ]]; then
    links="- None"
  fi

  local mid_yaml=""
  if [[ -n "${mids}" ]]; then
    mid_yaml=$'\n'"memory_ids:"
    while IFS= read -r m; do
      if [[ -n "${m}" ]]; then
        mid_yaml+=$'\n'"  - ${m}"
      fi
    done <<< "${mids}"
  fi

  cat > "${file}.tmp" <<EOF
---
id: ${singular}-${slug}
type: ${singular}
project_id: ${PROJECT_ID_DEFAULT}
created: ${today}
updated: ${today}
status: active${mid_yaml}
---
# ${title}

## Facts
${facts}

## Links
${links}
EOF
  mv "${file}.tmp" "${file}"
}

write_event_note() {
  local kind="$1"
  local key="$2"
  local date_str="$3"
  local text="$4"
  local links="$5"
  local mid="${6:-}"
  local label
  local short_hash="${key:0:8}"
  local title_slug
  title_slug="$(slugify "$(printf '%s' "${text}" | cut -c1-56)")"
  local file="${VAULT_DIR}/${kind}/${date_str}-${title_slug}-${short_hash}.md"
  local today
  today="$(date +%F)"
  case "${kind}" in
    decisions) label="Decision" ;;
    commitments) label="Commitment" ;;
    *) label="Event" ;;
  esac

  if [[ -z "${links}" ]]; then
    links="- None"
  fi

  local mid_yaml=""
  if [[ -n "${mid}" ]]; then
    mid_yaml=$'\n'"memory_id: ${mid}"
  fi

  cat > "${file}.tmp" <<EOF
---
id: ${kind%?}-${short_hash}
type: ${kind%?}
project_id: ${PROJECT_ID_DEFAULT}
created: ${date_str}
updated: ${today}
status: active${mid_yaml}
---
# ${label}: ${text}

## Canonical
- ${text}

## Links
${links}
EOF
  mv "${file}.tmp" "${file}"
}

declare -A PROJECT_FACTS
declare -A PROJECT_LINKS
declare -A PROJECT_MIDS
declare -A PERSON_TITLES
declare -A PERSON_FACTS
declare -A PERSON_LINKS
declare -A PERSON_MIDS
declare -A DECISIONS
declare -A DECISION_DATES
declare -A DECISION_LINKS
declare -A DECISION_MIDS
declare -A COMMITMENTS
declare -A COMMITMENT_DATES
declare -A COMMITMENT_LINKS
declare -A COMMITMENT_MIDS

load_project_map
load_people_map

if [[ "${REBUILD}" == "true" && -d "${VAULT_DIR}" ]]; then
  if [[ "${NO_BACKUP}" == "true" ]]; then
    purge_vault_contents
  else
    mkdir -p "${BACKUP_DIR}"
    mv "${VAULT_DIR}" "${BACKUP_DIR}/vault-$(date +%Y%m%d-%H%M%S)"
  fi
fi

mkdir -p "${VAULT_DIR}/projects" "${VAULT_DIR}/people" "${VAULT_DIR}/decisions" "${VAULT_DIR}/commitments"

while IFS= read -r file; do
  date_from_file="$(basename "${file}" .md)"
  if ! printf '%s\n' "${date_from_file}" | rg -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
    date_from_file="$(date +%F)"
  fi

  section=""
  while IFS= read -r raw_line; do
    line="${raw_line}"
    if [[ "${line}" =~ ^##[[:space:]]+(.+)$ ]]; then
      section="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
      continue
    fi
    if [[ -z "${line}" || "${line}" == \#* ]]; then
      continue
    fi

    local_mid="$(extract_mid "${line}")"
    line="$(clean_line "$(strip_mid "${line}")")"
    if [[ -z "${line}" ]]; then
      continue
    fi

    if [[ -z "${local_mid}" ]]; then
      local_mid="$(derive_mid_from_content "${line}")"
    fi

    if [[ "${PROMOTION_AWARE}" == "true" ]]; then
      if [[ -z "${PROMOTED_SET[${local_mid}]+_}" ]]; then
        continue
      fi
    fi

    links=""
    mentioned_projects=""
    mentioned_people=""

    for slug in "${!PROJECT_TITLES[@]}"; do
      if project_matches_line "${slug}" "${line}"; then
        append_unique_assoc PROJECT_FACTS "${slug}" "- (${date_from_file}) ${line}"
        append_unique_line_var links "[[projects/${slug}]]"
        append_unique_line_var mentioned_projects "${slug}"
        append_unique_assoc PROJECT_MIDS "${slug}" "${local_mid}"
      fi
    done

    while IFS= read -r handle; do
      person_slug="$(canonical_person_slug "${handle#@}")"
      if [[ -z "${person_slug}" ]]; then
        continue
      fi
      PERSON_TITLES["${person_slug}"]="$(canonical_person_title "${handle#@}")"
      append_unique_assoc PERSON_FACTS "${person_slug}" "- (${date_from_file}) ${line}"
      append_unique_line_var links "[[people/${person_slug}]]"
      append_unique_line_var mentioned_people "${person_slug}"
      append_unique_assoc PERSON_MIDS "${person_slug}" "${local_mid}"
    done < <(printf '%s\n' "${line}" | rg -o '@[A-Za-z0-9_][A-Za-z0-9_-]*' || true)

    if [[ -n "${PERSON_NAME_PATTERN}" ]]; then
      while IFS= read -r person; do
        person_slug="$(canonical_person_slug "${person}")"
        if [[ -z "${person_slug}" ]]; then
          continue
        fi
        PERSON_TITLES["${person_slug}"]="$(canonical_person_title "${person}")"
        append_unique_assoc PERSON_FACTS "${person_slug}" "- (${date_from_file}) ${line}"
        append_unique_line_var links "[[people/${person_slug}]]"
        append_unique_line_var mentioned_people "${person_slug}"
        append_unique_assoc PERSON_MIDS "${person_slug}" "${local_mid}"
      done < <(printf '%s\n' "${line}" | rg -oi -- "${PERSON_NAME_PATTERN}" || true)
    fi

    if printf '%s\n' "${links}" | rg -q .; then
      while IFS= read -r proj; do
        if [[ -z "${proj}" ]]; then
          continue
        fi
        while IFS= read -r link; do
          if [[ -n "${link}" && "${link}" != "[[projects/${proj}]]" ]]; then
            append_unique_assoc PROJECT_LINKS "${proj}" "- ${link}"
          fi
        done <<< "${links}"
      done <<< "${mentioned_projects}"

      while IFS= read -r person; do
        if [[ -z "${person}" ]]; then
          continue
        fi
        while IFS= read -r link; do
          if [[ -n "${link}" && "${link}" != "[[people/${person}]]" ]]; then
            append_unique_assoc PERSON_LINKS "${person}" "- ${link}"
          fi
        done <<< "${links}"
      done <<< "${mentioned_people}"
    fi

    if [[ "${section}" == "decisions" ]] || printf '%s\n' "${line}" | rg -qi 'Decision:|we chose|we decided|we will'; then
      key="$(printf '%s' "${line}" | sha1sum | awk '{print $1}')"
      DECISIONS["${key}"]="${line}"
      DECISION_DATES["${key}"]="${date_from_file}"
      DECISION_MIDS["${key}"]="${local_mid}"
      while IFS= read -r link; do
        if [[ -n "${link}" ]]; then
          append_unique_assoc DECISION_LINKS "${key}" "- ${link}"
        fi
      done <<< "${links}"
    fi

    if [[ "${section}" == "open todos" ]] || [[ "${section}" == "manual pins" ]] || printf '%s\n' "${line}" | rg -qi 'TODO:|\bTODO\b|I.?ll|deadline|due [0-9]{4}-[0-9]{2}-[0-9]{2}'; then
      key="$(printf '%s' "${line}" | sha1sum | awk '{print $1}')"
      COMMITMENTS["${key}"]="${line}"
      COMMITMENT_DATES["${key}"]="${date_from_file}"
      COMMITMENT_MIDS["${key}"]="${local_mid}"
      while IFS= read -r link; do
        if [[ -n "${link}" ]]; then
          append_unique_assoc COMMITMENT_LINKS "${key}" "- ${link}"
        fi
      done <<< "${links}"
    fi
  done < "${file}"
done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" | sort)

project_count=0
for slug in "${!PROJECT_FACTS[@]}"; do
  write_entity_note "projects" "${slug}" "${PROJECT_TITLES[${slug}]}" "${PROJECT_FACTS[${slug}]}" "${PROJECT_LINKS[${slug}]-}" "${PROJECT_MIDS[${slug}]-}"
  project_count=$((project_count + 1))
done

person_count=0
for slug in "${!PERSON_FACTS[@]}"; do
  write_entity_note "people" "${slug}" "${PERSON_TITLES[${slug}]}" "${PERSON_FACTS[${slug}]}" "${PERSON_LINKS[${slug}]-}" "${PERSON_MIDS[${slug}]-}"
  person_count=$((person_count + 1))
done

decision_count=0
for key in "${!DECISIONS[@]}"; do
  write_event_note "decisions" "${key}" "${DECISION_DATES[${key}]}" "${DECISIONS[${key}]}" "${DECISION_LINKS[${key}]-}" "${DECISION_MIDS[${key}]-}"
  decision_count=$((decision_count + 1))
done

commitment_count=0
for key in "${!COMMITMENTS[@]}"; do
  write_event_note "commitments" "${key}" "${COMMITMENT_DATES[${key}]}" "${COMMITMENTS[${key}]}" "${COMMITMENT_LINKS[${key}]-}" "${COMMITMENT_MIDS[${key}]-}"
  commitment_count=$((commitment_count + 1))
done

{
  printf '# Vault Index\n\n'
  printf 'Updated: %s\n\n' "$(date +%F)"
  if [[ ${project_count} -gt 0 ]]; then
    printf '## Projects\n'
    for slug in "${!PROJECT_FACTS[@]}"; do
      printf -- '- [[projects/%s]] — %s\n' "${slug}" "${PROJECT_TITLES[${slug}]}"
    done
    printf '\n'
  fi
  if [[ ${person_count} -gt 0 ]]; then
    printf '## People\n'
    for slug in "${!PERSON_FACTS[@]}"; do
      printf -- '- [[people/%s]] — %s\n' "${slug}" "${PERSON_TITLES[${slug}]}"
    done
    printf '\n'
  fi
  if [[ ${decision_count} -gt 0 ]]; then
    printf '## Decisions\n'
    for key in "${!DECISIONS[@]}"; do
      printf -- '- (%s) %s\n' "${DECISION_DATES[${key}]}" "${DECISIONS[${key}]}"
    done | sort
    printf '\n'
  fi
  if [[ ${commitment_count} -gt 0 ]]; then
    printf '## Commitments\n'
    for key in "${!COMMITMENTS[@]}"; do
      printf -- '- (%s) %s\n' "${COMMITMENT_DATES[${key}]}" "${COMMITMENTS[${key}]}"
    done | sort
    printf '\n'
  fi
} > "${VAULT_DIR}/index.md.tmp"
mv "${VAULT_DIR}/index.md.tmp" "${VAULT_DIR}/index.md"

echo "vault_sync: ok"
echo "projects: ${project_count}"
echo "people: ${person_count}"
echo "decisions: ${decision_count}"
echo "commitments: ${commitment_count}"
