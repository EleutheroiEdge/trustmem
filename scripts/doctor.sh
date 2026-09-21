#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
resolve_trustmem_paths "${SCRIPT_DIR}"

STRICT="${STRICT:-0}"
PROJECT_MAP_FILE="${PROJECT_MAP_FILE:-${TRUSTMEM_DIR}/projects-map.yaml}"

warn_count=0

ok() { printf 'OK   %s\n' "$1"; }
warn() {
  printf 'WARN %s\n' "$1"
  warn_count=$((warn_count + 1))
}
fail() {
  printf 'FAIL %s\n' "$1"
  exit 2
}

check_bin() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "binary present: ${cmd}"
  else
    warn "missing binary: ${cmd}"
  fi
}

check_file() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    ok "file present: ${f}"
  else
    warn "missing file: ${f}"
  fi
}

scan_secrets() {
  local root="$1"
  local tmp
  tmp="$(mktemp)"
  # Basic high-signal secret patterns only.
  if rg -n --hidden --glob '!.git' --glob '!vault/**' --glob '!vault-backups/**' \
    --glob '!config.example.yaml' --glob '!**/policies/**' --glob '!scripts/doctor.sh' \
    --glob '!tests/**' --glob '!docs/**' \
    '(ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN[[:space:]]+PRIVATE[[:space:]]+KEY)' "${root}" > "${tmp}"; then
    warn "possible secret-like content found under ${root}"
    sed -n '1,10p' "${tmp}"
  else
    ok "no high-signal secret patterns detected under ${root}"
  fi
  rm -f "${tmp}"
}

# The active policy is what the intake classifier enforces. An installation with
# an unreadable policy is fail-closed at intake, so report it loudly here.
check_policy() {
  if [[ -f "${POLICY_FILE}" ]]; then
    ok "active policy: ${POLICY_FILE}"
    local project_id
    project_id="$(policy_project_id "${POLICY_FILE}")"
    if [[ -n "${project_id}" ]]; then
      ok "policy scope.project_id: ${project_id}"
    else
      warn "policy has no scope.project_id; generated notes will use 'default'"
    fi
    if ! rg -q '^  never_store:' "${POLICY_FILE}"; then
      warn "policy has no filters.never_store list"
    fi
    if ! rg -q '^  block_patterns:' "${POLICY_FILE}"; then
      warn "policy has no filters.block_patterns list"
    fi
  else
    warn "active policy missing: ${POLICY_FILE} (intake will fail closed)"
  fi
}

check_scope_map() {
  if [[ -f "${PROJECT_MAP_FILE}" ]]; then
    ok "scope map present: ${PROJECT_MAP_FILE}"
  else
    warn "no ${PROJECT_MAP_FILE}; project and person scoping are disabled"
  fi
}

# Optional integration check for OpenClaw-style hosts. Skipped silently when no
# host config is configured or present.
check_embedding_guardrail() {
  local cfg="${OPENCLAW_CONFIG:-${WORKSPACE%/workspace}/openclaw.json}"
  if [[ ! -f "${cfg}" ]]; then
    ok "no host embedding config at ${cfg}; guardrail check skipped"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node missing; skipped host embedding guardrail check"
    return
  fi

  local status
  status="$(node - "${cfg}" <<'NODE'
const fs = require("fs");
const cfgPath = process.argv[2];
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
const ms = (((cfg||{}).agents||{}).defaults||{}).memorySearch || {};
const provider = ms.provider || "";
const model = ms.model || "";
let msg = "ok";
if (provider.toLowerCase() === "nvidia" && /nv-embedqa-e5-v5/i.test(model)) {
  const hasSplit = !!ms.indexModel || !!ms.queryModel;
  if (!hasSplit) {
    msg = "nvidia_dual_mode_warning";
  }
}
process.stdout.write(msg);
NODE
)"

  if [[ "${status}" == "nvidia_dual_mode_warning" ]]; then
    warn "NVIDIA nv-embedqa-e5-v5 selected in single-model memorySearch; dual-mode index/query split required"
  else
    ok "embedding config guardrail check passed"
  fi
}

check_scores_health() {
  local scores="${MEM_DIR}/.scores"
  if [[ ! -f "${scores}" ]]; then
    ok "scores file absent (not yet initialised)"
    return
  fi
  local total=0 bad=0
  while IFS=$'\t' read -r mid score _rest; do
    total=$((total + 1))
    if [[ -z "${mid}" || -z "${score}" ]]; then
      bad=$((bad + 1))
    elif ! [[ "${score}" =~ ^[0-9]+$ ]]; then
      bad=$((bad + 1))
    fi
  done < "${scores}"
  if [[ "${bad}" -gt 0 ]]; then
    warn "scores file has ${bad}/${total} malformed line(s)"
  else
    ok "scores file healthy (${total} entries)"
  fi
}

check_vault_health() {
  if [[ ! -d "${VAULT_DIR}" ]]; then
    ok "vault directory absent (not yet synced)"
    return
  fi
  local md_count=0
  while IFS= read -r -d '' _; do
    md_count=$((md_count + 1))
  done < <(find "${VAULT_DIR}" -type f -name "*.md" -print0 2>/dev/null)
  if [[ "${md_count}" -eq 0 ]]; then
    warn "vault directory exists but contains no .md files"
  else
    ok "vault contains ${md_count} Markdown file(s)"
  fi

  local index="${VAULT_DIR}/index.md"
  if [[ -f "${index}" ]]; then
    ok "vault index present"
  else
    warn "vault index.md missing — run 'trustmem sync'"
  fi
}

check_promoted_manifest() {
  local promoted="${MEM_DIR}/.promoted"
  local init_marker="${MEM_DIR}/.promoted_initialized"
  if [[ -f "${promoted}" ]]; then
    local count
    count="$(wc -l < "${promoted}" | tr -d ' ')"
    ok "promoted manifest present (${count} entries)"
  elif [[ -f "${init_marker}" ]]; then
    warn "promoted manifest missing but init marker exists — run 'trustmem sync --init-promoted'"
  else
    ok "promoted manifest not yet initialised"
  fi
}

main() {
  check_bin rg
  check_bin awk
  check_bin sed
  check_bin python3
  check_bin node

  check_file "${TRUSTMEM_DIR}/config.example.yaml"
  check_file "${TRUSTMEM_DIR}/.env.example"
  check_file "${TRUSTMEM_DIR}/projects-map.example.yaml"
  check_file "${TRUSTMEM_DIR}/policies/example-memory-policy.yaml"
  check_file "${TRUSTMEM_DIR}/scripts/memoryctl.sh"
  check_file "${TRUSTMEM_DIR}/scripts/vault_sync.sh"
  check_file "${TRUSTMEM_DIR}/scripts/livelearn.sh"
  check_file "${TRUSTMEM_DIR}/scripts/lib.sh"
  check_file "${TRUSTMEM_DIR}/scripts/memory_policy.py"

  check_policy
  check_scope_map
  check_scores_health
  check_vault_health
  check_promoted_manifest

  scan_secrets "${TRUSTMEM_DIR}"
  check_embedding_guardrail

  if [[ "${warn_count}" -gt 0 ]]; then
    if [[ "${STRICT}" == "1" ]]; then
      fail "doctor finished with ${warn_count} warning(s) in STRICT mode"
    fi
    printf 'Doctor finished with %s warning(s).\n' "${warn_count}"
  else
    printf 'Doctor finished cleanly.\n'
  fi
}

main "$@"
