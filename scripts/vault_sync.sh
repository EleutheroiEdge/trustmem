#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUSTMEM_DIR_DEFAULT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRUSTMEM_DIR="${TRUSTMEM_DIR:-$TRUSTMEM_DIR_DEFAULT}"
if [[ -d "${TRUSTMEM_DIR}/../memory" ]]; then
  WORKSPACE_DEFAULT="$(cd "${TRUSTMEM_DIR}/.." && pwd)"
else
  WORKSPACE_DEFAULT="${TRUSTMEM_DIR}"
fi
WORKSPACE="${WORKSPACE:-$WORKSPACE_DEFAULT}"
MEM_DIR="${MEM_DIR:-${WORKSPACE}/memory}"
VAULT_DIR="${VAULT_DIR:-${TRUSTMEM_DIR}/vault}"
BACKUP_DIR="${BACKUP_DIR:-${TRUSTMEM_DIR}/vault-backups}"
PROJECT_MAP_FILE="${PROJECT_MAP_FILE:-${TRUSTMEM_DIR}/projects-map.yaml}"
PROJECT_ID_DEFAULT="clawbot"

REBUILD=false
if [[ "${1:-}" == "--rebuild" ]]; then
  REBUILD=true
fi

slugify() {
  local input="${1,,}"
  input="$(printf '%s' "${input}" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "${input}" ]]; then
    input="item"
  fi
  printf '%s' "${input}"
}

canonical_person_slug() {
  local raw="${1,,}"
  case "${raw}" in
    markmyown) printf '' ;;
    mitzseen|mitazyn) printf 'mitzseen' ;;
    *) printf '%s' "$(slugify "${raw}")" ;;
  esac
}

canonical_person_title() {
  local raw="${1}"
  local slug
  slug="$(canonical_person_slug "${raw}")"
  case "${slug}" in
    mitzseen) printf 'Mitzseen' ;;
    *) printf '%s' "${raw}" ;;
  esac
}

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

load_project_map() {
  declare -gA PROJECT_TITLES
  declare -gA PROJECT_ALIASES

  if [[ -f "${PROJECT_MAP_FILE}" ]]; then
    while IFS=$'\t' read -r kind slug value; do
      if [[ "${kind}" == "TITLE" ]]; then
        PROJECT_TITLES["${slug}"]="${value}"
        append_unique_assoc PROJECT_ALIASES "${slug}" "${slug}"
      elif [[ "${kind}" == "ALIAS" ]]; then
        append_unique_assoc PROJECT_ALIASES "${slug}" "${value}"
      fi
    done < <(
      awk '
        BEGIN { in_projects=0; current=""; in_aliases=0 }
        /^projects:/ { in_projects=1; next }
        in_projects == 1 {
          if ($0 ~ /^[^[:space:]]/ && $0 !~ /^projects:/) { in_projects=0; current=""; in_aliases=0; next }
          if ($0 ~ /^  [a-z0-9-]+:/) {
            current=$1
            sub(":", "", current)
            in_aliases=0
            next
          }
          if (current == "") next
          if ($0 ~ /^    name:[[:space:]]*/) {
            v=$0
            sub(/^    name:[[:space:]]*/, "", v)
            gsub(/^"/, "", v)
            gsub(/"$/, "", v)
            print "TITLE\t" current "\t" v
            next
          }
          if ($0 ~ /^    aliases:[[:space:]]*$/) {
            in_aliases=1
            next
          }
          if (in_aliases == 1 && $0 ~ /^      -[[:space:]]*/) {
            v=$0
            sub(/^      -[[:space:]]*/, "", v)
            gsub(/^"/, "", v)
            gsub(/"$/, "", v)
            print "ALIAS\t" current "\t" v
            next
          }
          if (in_aliases == 1 && $0 !~ /^      -[[:space:]]*/) {
            in_aliases=0
          }
        }
      ' "${PROJECT_MAP_FILE}"
    )
  fi

  if [[ ${#PROJECT_TITLES[@]} -eq 0 ]]; then
    PROJECT_TITLES["clawbot"]="ClawBot"
    PROJECT_TITLES["trustmem"]="TrustMem"
    PROJECT_TITLES["proveustack"]="Proveustack"
    PROJECT_TITLES["markmyown"]="MarkMyOwn"
    PROJECT_TITLES["skimbot"]="Skimbot"
    PROJECT_TITLES["portfolio-optimizer"]="Portfolio Optimizer"
    PROJECT_TITLES["portfolio-rebalancer"]="Portfolio Rebalancer"
    PROJECT_TITLES["c3reb"]="C3Reb"
    for slug in "${!PROJECT_TITLES[@]}"; do
      append_unique_assoc PROJECT_ALIASES "${slug}" "${slug}"
    done
  fi
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

  cat > "${file}" <<EOF
---
id: ${singular}-${slug}
type: ${singular}
project_id: ${PROJECT_ID_DEFAULT}
created: ${today}
updated: ${today}
status: active
---
# ${title}

## Facts
${facts}

## Links
${links}
EOF
}

write_event_note() {
  local kind="$1"
  local key="$2"
  local date_str="$3"
  local text="$4"
  local links="$5"
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

  cat > "${file}" <<EOF
---
id: ${kind%?}-${short_hash}
type: ${kind%?}
project_id: ${PROJECT_ID_DEFAULT}
created: ${date_str}
updated: ${today}
status: active
---
# ${label}: ${text}

## Canonical
- ${text}

## Links
${links}
EOF
}

declare -A PROJECT_TITLES
declare -A PROJECT_ALIASES
declare -A PROJECT_FACTS
declare -A PROJECT_LINKS
declare -A PERSON_TITLES
declare -A PERSON_FACTS
declare -A PERSON_LINKS
declare -A DECISIONS
declare -A DECISION_DATES
declare -A DECISION_LINKS
declare -A COMMITMENTS
declare -A COMMITMENT_DATES
declare -A COMMITMENT_LINKS

load_project_map

if [[ "${REBUILD}" == "true" && -d "${VAULT_DIR}" ]]; then
  mkdir -p "${BACKUP_DIR}"
  mv "${VAULT_DIR}" "${BACKUP_DIR}/vault-$(date +%Y%m%d-%H%M%S)"
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

    line="$(printf '%s' "${line}" | sed -E 's/^- +//; s/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] +//')"
    if [[ -z "${line}" ]]; then
      continue
    fi

    links=""
    mentioned_projects=""
    mentioned_people=""

    for slug in "${!PROJECT_TITLES[@]}"; do
      if project_matches_line "${slug}" "${line}"; then
        append_unique_assoc PROJECT_FACTS "${slug}" "- (${date_from_file}) ${line}"
        append_unique_line_var links "[[projects/${slug}]]"
        append_unique_line_var mentioned_projects "${slug}"
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
    done < <(printf '%s\n' "${line}" | rg -o '@[A-Za-z0-9_][A-Za-z0-9_-]*' || true)

    for person in Mitzseen Mitazyn Josh Sam Alex; do
      if printf '%s\n' "${line}" | rg -qi "\\b${person}\\b"; then
        person_slug="$(canonical_person_slug "${person}")"
        if [[ -z "${person_slug}" ]]; then
          continue
        fi
        PERSON_TITLES["${person_slug}"]="$(canonical_person_title "${person}")"
        append_unique_assoc PERSON_FACTS "${person_slug}" "- (${date_from_file}) ${line}"
        append_unique_line_var links "[[people/${person_slug}]]"
        append_unique_line_var mentioned_people "${person_slug}"
      fi
    done

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
      while IFS= read -r link; do
        if [[ -n "${link}" ]]; then
          append_unique_assoc COMMITMENT_LINKS "${key}" "- ${link}"
        fi
      done <<< "${links}"
    fi
  done < "${file}"
done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" | sort)

for slug in "${!PROJECT_FACTS[@]}"; do
  write_entity_note "projects" "${slug}" "${PROJECT_TITLES[${slug}]}" "${PROJECT_FACTS[${slug}]}" "${PROJECT_LINKS[${slug}]-}"
done

for slug in "${!PERSON_FACTS[@]}"; do
  write_entity_note "people" "${slug}" "${PERSON_TITLES[${slug}]}" "${PERSON_FACTS[${slug}]}" "${PERSON_LINKS[${slug}]-}"
done

decision_count=0
for key in "${!DECISIONS[@]}"; do
  write_event_note "decisions" "${key}" "${DECISION_DATES[${key}]}" "${DECISIONS[${key}]}" "${DECISION_LINKS[${key}]-}"
  decision_count=$((decision_count + 1))
done

commitment_count=0
for key in "${!COMMITMENTS[@]}"; do
  write_event_note "commitments" "${key}" "${COMMITMENT_DATES[${key}]}" "${COMMITMENTS[${key}]}" "${COMMITMENT_LINKS[${key}]-}"
  commitment_count=$((commitment_count + 1))
done

echo "vault_sync: ok"
echo "projects: ${#PROJECT_FACTS[@]}"
echo "people: ${#PERSON_FACTS[@]}"
echo "decisions: ${decision_count}"
echo "commitments: ${commitment_count}"
