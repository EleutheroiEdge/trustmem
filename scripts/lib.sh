#!/usr/bin/env bash
# lib.sh — Shared helpers for TrustMem scripts.
# Source this file; do not execute directly.

# shellcheck disable=SC2034
TRUSTMEM_VERSION="0.3.0"

# ── Path helpers ─────────────────────────────────────────────────────

# Resolve the policy file for this installation.
#   1. POLICY_FILE           — explicit path wins.
#   2. TRUSTMEM_POLICY_PROFILE — policies/<profile>-memory-policy.yaml
#   3. the shipped generic example profile.
# A private consumer drops its own profile into policies/ (non-example
# profiles are git-ignored) or points POLICY_FILE somewhere outside the repo.
resolve_policy_path() {
  local trustmem_dir="$1" profile="${2:-}"
  if [[ -n "${POLICY_FILE:-}" ]]; then
    printf '%s' "${POLICY_FILE}"
    return
  fi
  if [[ -z "${profile}" ]]; then
    profile="example"
  fi
  printf '%s' "${trustmem_dir}/policies/${profile}-memory-policy.yaml"
}

# Read scope.project_id from the active policy. Used to stamp generated vault
# front-matter. Nothing here is hard-coded to any particular deployment.
policy_project_id() {
  local policy="$1"
  if [[ ! -f "${policy}" ]]; then
    return
  fi
  awk '
    /^scope:[[:space:]]*$/ { in_scope = 1; next }
    /^[^[:space:]]/        { in_scope = 0 }
    in_scope == 1 && $0 ~ /^[[:space:]][[:space:]]project_id:/ {
      value = $0
      sub(/^[[:space:]][[:space:]]project_id:[[:space:]]*/, "", value)
      gsub(/"/, "", value)
      print value
      exit
    }
  ' "${policy}"
}

resolve_trustmem_paths() {
  local script_dir="$1"
  TRUSTMEM_DIR_DEFAULT="$(cd "${script_dir}/.." && pwd)"
  TRUSTMEM_DIR="${TRUSTMEM_DIR:-$TRUSTMEM_DIR_DEFAULT}"
  if [[ -d "${TRUSTMEM_DIR}/../memory" ]]; then
    WORKSPACE_DEFAULT="$(cd "${TRUSTMEM_DIR}/.." && pwd)"
  else
    WORKSPACE_DEFAULT="${TRUSTMEM_DIR}"
  fi
  WORKSPACE="${WORKSPACE:-$WORKSPACE_DEFAULT}"
  MEM_DIR="${MEM_DIR:-${WORKSPACE}/memory}"
  VAULT_DIR="${VAULT_DIR:-${TRUSTMEM_DIR}/vault}"
  POLICY_FILE="$(resolve_policy_path "${TRUSTMEM_DIR}" "${TRUSTMEM_POLICY_PROFILE:-}")"
}

validate_memory_text() {
  local text="$1" category="${2:-}" confirmed="${3:-0}" ambiguous="${4:-0}"
  local classifier="${MEMORY_POLICY_CLASSIFIER:-${TRUSTMEM_DIR}/scripts/memory_policy.py}"
  local python_bin="${PYTHON_BIN:-python3}"
  local args=(validate --policy "${POLICY_FILE}" --text "${text}")
  if [[ -n "${category}" ]]; then args+=(--category "${category}"); fi
  if [[ "${confirmed}" == "1" ]]; then args+=(--confirmed); fi
  if [[ "${ambiguous}" == "1" ]]; then args+=(--ambiguous); fi
  "${python_bin}" "${classifier}" "${args[@]}"
}

# Remove generated vault files that reference one or more memory IDs. Entity
# notes may aggregate multiple memories, so delete the generated note rather
# than attempting an unsafe line-level edit; vault_sync recreates it from the
# surviving source rows. Removing index.md prevents an index-only stale copy if
# the subsequent rebuild cannot run.
scrub_vault_memory_ids() {
  local mids="$1"
  local mid file
  if [[ ! -d "${VAULT_DIR}" ]]; then
    return
  fi
  if [[ -z "${VAULT_DIR}" || "${VAULT_DIR}" == "/" || "${VAULT_DIR}" == "${TRUSTMEM_DIR}" || "${VAULT_DIR}" == "${WORKSPACE}" || -L "${VAULT_DIR}" ]]; then
    echo "trustmem: refusing unsafe vault scrub target: ${VAULT_DIR}" >&2
    return 2
  fi
  while IFS= read -r mid; do
    if [[ -z "${mid}" ]]; then
      continue
    fi
    while IFS= read -r -d '' file; do
      unlink "${file}"
    done < <(rg -l -0 --fixed-strings -- "${mid}" "${VAULT_DIR}" 2>/dev/null || true)
  done <<< "${mids}"
  if [[ -f "${VAULT_DIR}/index.md" ]]; then
    unlink "${VAULT_DIR}/index.md"
  fi
}

# ── Memory-ID helpers ────────────────────────────────────────────────

generate_mid() {
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16
}

extract_mid() {
  local line="$1"
  if [[ "${line}" =~ \[mid:([a-f0-9]{16})\] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

strip_mid() {
  printf '%s' "$1" | sed -E 's/\[mid:[a-f0-9]{16}\] ?//'
}

derive_mid_from_content() {
  printf '%s' "$1" | sha1sum | cut -c1-16
}

clean_line() {
  printf '%s' "$1" | sed -E 's/^- +//; s/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] +//'
}

# ── Category helpers ─────────────────────────────────────────────────

category_weight() {
  local section="${1,,}"
  case "${section}" in
    decisions)    printf '100' ;;
    preferences)  printf '90' ;;
    constraints)  printf '85' ;;
    *todo*)       printf '80' ;;
    *pin*)        printf '80' ;;
    *)            printf '85' ;;
  esac
}

# Return the retention period (days) for a given category.
# Falls back to 90 days for uncategorised entries.
category_retention_days() {
  local section="${1,,}"
  case "${section}" in
    decisions)    printf '365' ;;
    preferences)  printf '3650' ;;
    constraints)  printf '365' ;;
    *todo*)       printf '90' ;;
    *pin*)        printf '90' ;;
    *)            printf '90' ;;
  esac
}

# ── Slug / text helpers ──────────────────────────────────────────────

slugify() {
  local input="${1,,}"
  input="$(printf '%s' "${input}" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "${input}" ]]; then
    input="item"
  fi
  printf '%s' "${input}"
}

# Escape a literal string so it can be used inside a regex alternation.
# Deliberately blunt: everything that is not alphanumeric, underscore or space
# gets a backslash, which is always safe and never changes the match.
regex_escape() {
  printf '%s' "$1" | sed -E 's/[^a-zA-Z0-9_ ]/\\&/g'
}
