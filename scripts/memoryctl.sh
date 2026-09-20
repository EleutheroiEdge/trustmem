#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
resolve_trustmem_paths "${SCRIPT_DIR}"

VAULT_SYNC_SCRIPT="${VAULT_SYNC_SCRIPT:-${TRUSTMEM_DIR}/scripts/vault_sync.sh}"
LIVELEARN_SCRIPT="${LIVELEARN_SCRIPT:-${TRUSTMEM_DIR}/scripts/livelearn.sh}"
PROMOTED_FILE="${MEM_DIR}/.promoted"
SCORES_FILE="${MEM_DIR}/.scores"

usage() {
  cat <<'USAGE'
Usage:
  memoryctl.sh remember [--confirm] [--category <name>] [--ambiguous] "<text>"
  memoryctl.sh ingest [--confirm] [--category <name>] [--ambiguous] "<text>"
  memoryctl.sh forget "<pattern>"
  memoryctl.sh recall "<query>"
  memoryctl.sh sync [--rebuild] [--init-promoted]
USAGE
}

ensure_paths() {
  mkdir -p "${MEM_DIR}"
  mkdir -p "$(dirname "${VAULT_SYNC_SCRIPT}")"
}


add_to_promoted() {
  local mid="$1" source_file="$2"
  local ts
  ts="$(date -Iseconds)"
  printf '%s\t%s\t%s\n' "${mid}" "${source_file}" "${ts}" >> "${PROMOTED_FILE}"
}

remove_from_promoted() {
  local pattern="$1"
  if [[ ! -f "${PROMOTED_FILE}" ]]; then return; fi
  local tmp="${PROMOTED_FILE}.tmp"
  rg -v --fixed-strings -- "${pattern}" "${PROMOTED_FILE}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${PROMOTED_FILE}"
}

remove_from_scores() {
  local pattern="$1"
  if [[ ! -f "${SCORES_FILE}" ]]; then return; fi
  local tmp="${SCORES_FILE}.tmp"
  rg -v --fixed-strings -- "${pattern}" "${SCORES_FILE}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${SCORES_FILE}"
}

run_livelearn_score() {
  if [[ ! -x "${LIVELEARN_SCRIPT}" ]]; then
    chmod +x "${LIVELEARN_SCRIPT}" 2>/dev/null || true
  fi
  if [[ -x "${LIVELEARN_SCRIPT}" ]]; then
    "${LIVELEARN_SCRIPT}" score
  fi
}

run_vault_sync() {
  if [[ ! -x "${VAULT_SYNC_SCRIPT}" ]]; then
    chmod +x "${VAULT_SYNC_SCRIPT}"
  fi
  "${VAULT_SYNC_SCRIPT}" "$@"
}

today_file() {
  date +"%Y-%m-%d"
}

init_today_file() {
  local day="$1" file="$2"
  if [[ ! -f "${file}" ]]; then
    cat > "${file}" <<EOF
# ${day}

## Decisions

## Preferences

## Constraints

## Open TODOs

## Manual Pins
EOF
  fi
}

append_today_note() {
  local text="$1" category="${2:-}" confirmed="${3:-0}" ambiguous="${4:-0}"
  local day file stamp mid
  validate_memory_text "${text}" "${category}" "${confirmed}" "${ambiguous}"
  day="$(today_file)"
  file="${MEM_DIR}/${day}.md"
  stamp="$(date +"%H:%M:%S")"
  mid="$(generate_mid)"

  init_today_file "${day}" "${file}"

  if ! rg -q "^## Manual Pins$" "${file}"; then
    printf "\n## Manual Pins\n" >> "${file}"
  fi

  printf -- "- [mid:%s] [%s] %s\n" "${mid}" "${stamp}" "${text}" >> "${file}"
  add_to_promoted "${mid}" "${day}.md"
  echo "remembered: ${file} [mid:${mid}]"
}

ingest_note() {
  local text="$1" category="${2:-}" confirmed="${3:-0}" ambiguous="${4:-0}"
  local day file stamp mid
  validate_memory_text "${text}" "${category}" "${confirmed}" "${ambiguous}"
  day="$(today_file)"
  file="${MEM_DIR}/${day}.md"
  stamp="$(date +"%H:%M:%S")"
  mid="$(generate_mid)"

  init_today_file "${day}" "${file}"

  if ! rg -q "^## Manual Pins$" "${file}"; then
    printf "\n## Manual Pins\n" >> "${file}"
  fi

  printf -- "- [mid:%s] [%s] %s\n" "${mid}" "${stamp}" "${text}" >> "${file}"
  echo "ingested: ${file} [mid:${mid}]"
}

forget_pattern() {
  local pattern="$1"
  local removed=0
  local forgotten_mids=""
  local f tmp

  while IFS= read -r -d '' f; do
    tmp="${f}.tmp"
    if rg -qi --fixed-strings -- "${pattern}" "${f}"; then
      while IFS= read -r matched_line; do
        local mid
        mid="$(extract_mid "${matched_line}")"
        if [[ -n "${mid}" ]]; then
          forgotten_mids="${forgotten_mids}${mid}"$'\n'
        fi
      done < <(rg -i --fixed-strings -- "${pattern}" "${f}" 2>/dev/null || true)
      awk -v pat="${pattern}" 'index(tolower($0), tolower(pat))==0 {print}' "${f}" > "${tmp}"
      mv "${tmp}" "${f}"
      removed=$((removed + 1))
    fi
  done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" -print0)

  if [[ -n "${forgotten_mids}" ]]; then
    while IFS= read -r mid; do
      if [[ -n "${mid}" ]]; then
        remove_from_promoted "${mid}"
        remove_from_scores "${mid}"
      fi
    done <<< "${forgotten_mids}"
    scrub_vault_memory_ids "${forgotten_mids}"
  fi

  echo "forgotten_pattern: ${pattern}"
  echo "files_changed: ${removed}"
}

score_for_mid() {
  local mid="$1"
  if [[ ! -f "${SCORES_FILE}" || -z "${mid}" ]]; then return; fi
  local line
  line="$(awk -F'\t' -v h="${mid}" '$1 == h { print; exit }' "${SCORES_FILE}" 2>/dev/null || true)"
  if [[ -n "${line}" ]]; then
    local score reinf
    score="$(printf '%s' "${line}" | cut -f2)"
    reinf="$(printf '%s' "${line}" | cut -f5)"
    printf '[score:%s reinf:%s]' "${score}" "${reinf}"
  fi
}

recall_query() {
  local query="$1"
  local vault_hits=0

  # ── Search vault (primary) ──
  if [[ -d "${VAULT_DIR}" ]]; then
    local index="${VAULT_DIR}/index.md"
    local index_results=""
    if [[ -f "${index}" ]]; then
      index_results="$(rg -i --fixed-strings -- "${query}" "${index}" 2>/dev/null || true)"
    fi
    if [[ -n "${index_results}" ]]; then
      echo "## Index matches"
      printf '%s\n' "${index_results}"
      echo ""
    fi

    echo "## Vault matches"
    while IFS= read -r match; do
      local rel="${match#"${VAULT_DIR}"/}"
      local mid_from_vault=""
      mid_from_vault="$(rg '^memory_id:' "${match}" 2>/dev/null | head -1 | sed 's/memory_id: *//' || true)"
      local score_info=""
      if [[ -n "${mid_from_vault}" ]]; then
        score_info="$(score_for_mid "${mid_from_vault}")"
      fi
      if [[ -n "${score_info}" ]]; then
        echo "--- ${rel} ${score_info} ---"
      else
        echo "--- ${rel} ---"
      fi
      rg -i -C 1 --fixed-strings -- "${query}" "${match}"
      echo ""
      vault_hits=$((vault_hits + 1))
    done < <(rg -il --fixed-strings -- "${query}" "${VAULT_DIR}" 2>/dev/null || true)
  fi

  # ── Fallback: search day-files when vault returned no results ──
  if [[ "${vault_hits}" -eq 0 && -d "${MEM_DIR}" ]]; then
    echo "## Day-file matches (vault empty or no vault hits)"
    local day_hits=0
    while IFS= read -r match; do
      local rel
      rel="$(basename "${match}")"
      echo "--- ${rel} ---"
      rg -i -C 1 --fixed-strings -- "${query}" "${match}"
      echo ""
      day_hits=$((day_hits + 1))
    done < <(rg -il --fixed-strings -- "${query}" "${MEM_DIR}"/*.md 2>/dev/null || true)
    echo "recall: ${day_hits} day-file(s) matched"
  else
    echo "recall: ${vault_hits} file(s) matched"
  fi
}

init_promoted() {
  if [[ -f "${PROMOTED_FILE}" ]]; then
    echo "init-promoted: ${PROMOTED_FILE} already exists. Remove it first to re-initialize." >&2
    return 1
  fi
  local count=0
  local ts
  ts="$(date -Iseconds)"

  while IFS= read -r file; do
    local basename_file
    basename_file="$(basename "${file}")"
    while IFS= read -r raw_line; do
      if [[ -z "${raw_line}" || "${raw_line}" == \#* ]]; then
        continue
      fi
      local mid
      mid="$(extract_mid "${raw_line}")"
      if [[ -z "${mid}" ]]; then
        local cleaned
        cleaned="$(clean_line "$(strip_mid "${raw_line}")")"
        if [[ -z "${cleaned}" ]]; then continue; fi
        mid="$(derive_mid_from_content "${cleaned}")"
      fi
      printf '%s\t%s\t%s\n' "${mid}" "${basename_file}" "${ts}" >> "${PROMOTED_FILE}"
      count=$((count + 1))
    done < "${file}"
  done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" | sort)

  touch "${MEM_DIR}/.promoted_initialized"
  echo "init-promoted: ok"
  echo "entries: ${count}"
}

parse_intake_args() {
  INTAKE_CATEGORY=""
  INTAKE_CONFIRMED=0
  INTAKE_AMBIGUOUS=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --confirm)
        INTAKE_CONFIRMED=1
        shift
        ;;
      --ambiguous)
        INTAKE_AMBIGUOUS=1
        shift
        ;;
      --category)
        if [[ $# -lt 2 ]]; then
          echo "trustmem: --category requires a value" >&2
          return 2
        fi
        INTAKE_CATEGORY="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      --*)
        echo "trustmem: unknown intake option: $1" >&2
        return 2
        ;;
      *)
        break
        ;;
    esac
  done
  INTAKE_TEXT="$*"
  if [[ -z "${INTAKE_TEXT//[[:space:]]/}" ]]; then
    echo "trustmem: memory text is required" >&2
    return 2
  fi
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  ensure_paths
  local cmd="$1"
  shift

  case "${cmd}" in
    remember)
      parse_intake_args "$@"
      append_today_note "${INTAKE_TEXT}" "${INTAKE_CATEGORY}" "${INTAKE_CONFIRMED}" "${INTAKE_AMBIGUOUS}"
      run_livelearn_score
      run_vault_sync
      ;;
    ingest)
      parse_intake_args "$@"
      ingest_note "${INTAKE_TEXT}" "${INTAKE_CATEGORY}" "${INTAKE_CONFIRMED}" "${INTAKE_AMBIGUOUS}"
      run_livelearn_score
      ;;
    forget)
      forget_pattern "$*"
      # A forget operation must not preserve the forgotten content in the normal
      # rebuild backup. Recreate the generated vault from surviving day-file rows.
      run_vault_sync --rebuild --no-backup
      ;;
    recall)
      recall_query "$*"
      ;;
    sync)
      if [[ "${1:-}" == "--init-promoted" ]]; then
        init_promoted
      else
        run_vault_sync "$@"
      fi
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
