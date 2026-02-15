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
STRICT="${STRICT:-0}"

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
    '(ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN[[:space:]]+PRIVATE[[:space:]]+KEY)' "${root}" > "${tmp}"; then
    warn "possible secret-like content found under ${root}"
    sed -n '1,10p' "${tmp}"
  else
    ok "no high-signal secret patterns detected under ${root}"
  fi
  rm -f "${tmp}"
}

check_openclaw_embedding_guardrail() {
  local cfg="${WORKSPACE%/workspace}/openclaw.json"
  if [[ ! -f "${cfg}" ]]; then
    warn "openclaw.json not found at ${cfg}; skipped embedding guardrail checks"
    return
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node missing; skipped openclaw embedding guardrail checks"
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

main() {
  check_bin rg
  check_bin awk
  check_bin sed
  check_bin node

  check_file "${TRUSTMEM_DIR}/config.example.yaml"
  check_file "${TRUSTMEM_DIR}/.env.example"
  check_file "${TRUSTMEM_DIR}/projects-map.example.yaml"
  check_file "${TRUSTMEM_DIR}/scripts/memoryctl.sh"
  check_file "${TRUSTMEM_DIR}/scripts/vault_sync.sh"

  scan_secrets "${TRUSTMEM_DIR}"
  check_openclaw_embedding_guardrail

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
