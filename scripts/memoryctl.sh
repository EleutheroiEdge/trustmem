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
VAULT_SYNC_SCRIPT="${VAULT_SYNC_SCRIPT:-${TRUSTMEM_DIR}/scripts/vault_sync.sh}"

usage() {
  cat <<'USAGE'
Usage:
  memoryctl.sh remember "<text>"
  memoryctl.sh forget "<pattern>"
  memoryctl.sh sync [--rebuild]
USAGE
}

ensure_paths() {
  mkdir -p "${MEM_DIR}"
  mkdir -p "$(dirname "${VAULT_SYNC_SCRIPT}")"
}

run_vault_sync() {
  local mode="${1:-}"
  if [[ ! -x "${VAULT_SYNC_SCRIPT}" ]]; then
    chmod +x "${VAULT_SYNC_SCRIPT}"
  fi
  if [[ "${mode}" == "--rebuild" ]]; then
    "${VAULT_SYNC_SCRIPT}" --rebuild
  else
    "${VAULT_SYNC_SCRIPT}"
  fi
}

today_file() {
  date +"%Y-%m-%d"
}

append_today_note() {
  local text="$1"
  local day file stamp
  day="$(today_file)"
  file="${MEM_DIR}/${day}.md"
  stamp="$(date +"%H:%M:%S")"

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

  if ! rg -q "^## Manual Pins$" "${file}"; then
    printf "\n## Manual Pins\n" >> "${file}"
  fi

  printf -- "- [%s] %s\n" "${stamp}" "${text}" >> "${file}"
  echo "remembered: ${file}"
}

forget_pattern() {
  local pattern="$1"
  local removed=0
  local f tmp

  while IFS= read -r -d '' f; do
    tmp="${f}.tmp"
    if rg -qi --fixed-strings -- "${pattern}" "${f}"; then
      awk -v pat="${pattern}" 'BEGIN{IGNORECASE=1} index(tolower($0), tolower(pat))==0 {print}' "${f}" > "${tmp}"
      mv "${tmp}" "${f}"
      removed=$((removed + 1))
    fi
  done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" -print0)

  echo "forgotten_pattern: ${pattern}"
  echo "files_changed: ${removed}"
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
      append_today_note "$*"
      run_vault_sync --rebuild
      ;;
    forget)
      forget_pattern "$*"
      run_vault_sync --rebuild
      ;;
    sync)
      if [[ "${1:-}" == "--rebuild" ]]; then
        run_vault_sync --rebuild
      else
        run_vault_sync
      fi
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
