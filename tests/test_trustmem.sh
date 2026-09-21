#!/usr/bin/env bash
# test_trustmem.sh — Functional test suite for TrustMem.
#
# Run:  bash tests/test_trustmem.sh
# Exit: 0 on success, 1 on failure
#
# Every fixture in this suite is synthetic. No real memory content, identity,
# credential or project name appears anywhere in this file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUSTMEM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="$(mktemp -d)"
BIN="${TRUSTMEM_DIR}/bin/trustmem"
FIXTURES="${SCRIPT_DIR}/fixtures"

export TRUSTMEM_DIR
export WORKSPACE="${TEST_DIR}"
export MEM_DIR="${TEST_DIR}/memory"
export VAULT_DIR="${TEST_DIR}/vault"
export BACKUP_DIR="${TEST_DIR}/vault-backups"
# Scoping is configuration, not a built-in: default the suite to "no map" so
# any project/person note proves a map was supplied.
export PROJECT_MAP_FILE="${TEST_DIR}/absent-projects-map.yaml"

pass=0
fail=0

setup() {
  rm -rf "${TEST_DIR:?}"/*
  mkdir -p "${MEM_DIR}" "${VAULT_DIR}"
}

cleanup() {
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "${label}"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n' "${label}"
    printf '    expected: %s\n' "${expected}"
    printf '    actual:   %s\n' "${actual}"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "${label}"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n' "${label}"
    printf '    expected to contain: %s\n' "${needle}"
    printf '    got: %s\n' "${haystack}"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! printf '%s' "${haystack}" | grep -qF "${needle}"; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "${label}"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n' "${label}"
    printf '    expected NOT to contain: %s\n' "${needle}"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "${path}" ]]; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "${label}"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n' "${label}"
    printf '    file does not exist: %s\n' "${path}"
  fi
}

assert_file_absent() {
  local label="$1" path="$2"
  if [[ ! -e "${path}" ]]; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "${label}"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n' "${label}"
    printf '    file unexpectedly exists: %s\n' "${path}"
  fi
}

assert_refused() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail=$((fail + 1))
    printf '  FAIL  %s (command succeeded)\n' "${label}"
  else
    pass=$((pass + 1))
    printf '  PASS  %s\n' "${label}"
  fi
}

# ── Tests ────────────────────────────────────────────────────────────

test_version() {
  echo "=== test_version ==="
  local out
  out="$("${BIN}" --version 2>&1)"
  assert_contains "version output" "trustmem" "${out}"
  assert_contains "version number" "0.3.0" "${out}"
}

test_remember() {
  echo "=== test_remember ==="
  setup
  local out
  out="$("${BIN}" remember "Unit test decision: use Bash" 2>&1)"
  assert_contains "remember output" "remembered:" "${out}"

  local today
  today="$(date +%Y-%m-%d)"
  local day_file="${MEM_DIR}/${today}.md"
  assert_file_exists "day-file created" "${day_file}"

  local content
  content="$(cat "${day_file}")"
  assert_contains "entry in day-file" "Unit test decision: use Bash" "${content}"
  assert_contains "mid tag in day-file" "[mid:" "${content}"

  assert_file_exists "promoted manifest created" "${MEM_DIR}/.promoted"
  assert_file_exists "scores file created" "${MEM_DIR}/.scores"
}

test_policy_block() {
  echo "=== test_policy_block ==="
  setup
  assert_refused "blocked policy pattern refused" \
    "${BIN}" remember "blocked synthetic sk-example"

  local today
  today="$(date +%Y-%m-%d)"
  assert_file_absent "rejected memory was not written" "${MEM_DIR}/${today}.md"

  assert_refused "semantic raw credential refused" \
    "${BIN}" remember "password=synthetic-secret"
  assert_refused "private key header refused" \
    "${BIN}" remember "key material -----BEGIN RSA PRIVATE KEY----- synthetic"
  assert_refused "declared never_store category refused" \
    "${BIN}" remember --category full_transcripts "a perfectly ordinary sentence"
  assert_refused "sensitive content requires confirmation" \
    "${BIN}" remember "Contact test@example.com"

  local confirmed_out
  confirmed_out="$("${BIN}" remember --confirm "Contact test@example.com" 2>&1)"
  assert_contains "confirmed sensitive content accepted" "remembered:" "${confirmed_out}"

  assert_refused "ambiguous content routed to review" \
    "${BIN}" ingest --ambiguous "synthetic uncertain note"
  assert_refused "confirmation cannot override a denial" \
    "${BIN}" remember --confirm "blocked synthetic sk-example"
}

test_full_transcript_block() {
  echo "=== test_full_transcript_block ==="
  setup
  assert_refused "explicitly marked transcript refused" \
    "${BIN}" remember "Transcript: the whole synthetic conversation"
  # Four or more role-prefixed lines are treated as a full transcript.
  local roles
  roles="$(printf 'user: one\nassistant: two\nuser: three\nassistant: four\n')"
  assert_refused "role-line transcript refused" "${BIN}" remember "${roles}"

  local today
  today="$(date +%Y-%m-%d)"
  assert_file_absent "no day-file after transcript refusals" "${MEM_DIR}/${today}.md"
}

test_policy_profile_is_configurable() {
  echo "=== test_policy_profile_is_configurable ==="
  setup
  # The fixture profile blocks a token the shipped example policy allows.
  assert_refused "fixture policy blocks its own pattern" \
    env POLICY_FILE="${FIXTURES}/strict-memory-policy.yaml" \
    "${BIN}" remember "note containing zzq-fixture-blocked marker"

  local out
  out="$("${BIN}" remember "note containing zzq-fixture-blocked marker" 2>&1)"
  assert_contains "default policy allows that same text" "remembered:" "${out}"

  local today
  today="$(date +%Y-%m-%d)"
  local content
  content="$(cat "${MEM_DIR}/${today}.md")"
  assert_contains "text stored under the default policy" "zzq-fixture-blocked" "${content}"
}

test_ingest() {
  echo "=== test_ingest ==="
  setup
  local out
  out="$("${BIN}" ingest "Ingested note about testing" 2>&1)"
  assert_contains "ingest output" "ingested:" "${out}"

  local today
  today="$(date +%Y-%m-%d)"
  local content
  content="$(cat "${MEM_DIR}/${today}.md")"
  assert_contains "entry in day-file" "Ingested note about testing" "${content}"

  # ingest does NOT add to promoted (only to scores via livelearn)
  if [[ -f "${MEM_DIR}/.promoted" ]]; then
    local prom_content
    prom_content="$(cat "${MEM_DIR}/.promoted")"
    assert_eq "promoted empty after ingest" "" "${prom_content}"
  else
    pass=$((pass + 1))
    printf '  PASS  no promoted file after ingest (correct)\n'
  fi
}

test_forget() {
  echo "=== test_forget ==="
  setup
  "${BIN}" remember "Keep this note" >/dev/null 2>&1
  "${BIN}" remember "Forget this note" >/dev/null 2>&1

  local out
  out="$("${BIN}" forget "Forget this" 2>&1)"
  assert_contains "forget output" "forgotten_pattern:" "${out}"

  local today
  today="$(date +%Y-%m-%d)"
  local content
  content="$(cat "${MEM_DIR}/${today}.md")"
  assert_contains "kept entry survives" "Keep this note" "${content}"
  assert_not_contains "forgotten entry removed" "Forget this note" "${content}"
  local vault_content
  vault_content="$(find "${VAULT_DIR}" -type f -name '*.md' -exec cat {} +)"
  assert_contains "kept vault entry survives" "Keep this note" "${vault_content}"
  assert_not_contains "forgotten vault entry removed" "Forget this note" "${vault_content}"

  assert_file_absent "forget created no stale vault backup" "${BACKUP_DIR}"

  local scores_content
  scores_content="$(cat "${MEM_DIR}/.scores")"
  assert_not_contains "forgotten mid removed from scores" "Forget this note" "${scores_content}"
}

# Explicit forget is the privacy/deletion EXCEPTION to the append-only lifecycle: it may rewrite day-files, and afterwards
# no recoverable copy may remain in TrustMem-managed current/generated/backup artifacts. Cleanup is keyed on the exact
# memory id, so the fixtures below mirror what the engine really writes (ids in rows and in note front matter).
_mid_of() { extract_mid "$(grep -F -- "$1" "${MEM_DIR}/$(date +%Y-%m-%d).md" | head -n 1)"; }

test_forget_leaves_no_recoverable_copy() {
  echo "=== test_forget_leaves_no_recoverable_copy ==="
  setup
  "${BIN}" remember "Keep this synthetic note" >/dev/null 2>&1
  "${BIN}" remember "Erase this synthetic zebra-plan note" >/dev/null 2>&1
  "${BIN}" learn score >/dev/null 2>&1

  local today mid keep_mid
  today="$(date +%Y-%m-%d)"
  mid="$(_mid_of 'Erase this synthetic')"
  keep_mid="$(_mid_of 'Keep this synthetic')"
  assert_eq "fixture has a memory id" "16" "${#mid}"

  # access-log rows as written by reinforce/promote/prune (epoch, action, MID, snippet)
  printf '%s\t%s\t%s\t%s\n' "1700000000" "reinforce" "${mid}" "Erase this synthetic zebra-plan note" >> "${MEM_DIR}/.access_log"
  printf '%s\t%s\t%s\t%s\n' "1700000001" "reinforce" "${keep_mid}" "Keep this synthetic note" >> "${MEM_DIR}/.access_log"
  # a vault backup from an EARLIER rebuild: generated notes reference their sources in front matter
  local snap="${BACKUP_DIR}/vault-20000101-000000"
  mkdir -p "${snap}/decisions"
  printf '%s\n' '---' "memory_id: ${mid}" '---' '- Erase this synthetic zebra-plan note' > "${snap}/decisions/erase.md"
  printf '%s\n' '---' "memory_id: ${keep_mid}" '---' '- Keep this synthetic note' > "${snap}/decisions/keep.md"
  printf '%s\n' '- decisions/erase: Erase this synthetic zebra-plan note' '- decisions/keep: Keep this synthetic note' > "${snap}/index.md"

  "${BIN}" forget "zebra-plan" >/dev/null 2>&1

  local everything
  everything="$(find "${MEM_DIR}" "${VAULT_DIR}" "${BACKUP_DIR}" -type f -exec cat {} + 2>/dev/null)"
  assert_not_contains "forgotten text remains in no TrustMem-managed artifact" "zebra-plan" "${everything}"
  assert_not_contains "forgotten memory id remains in no TrustMem-managed artifact" "${mid}" "${everything}"
  assert_contains "unrelated day-file entry survives" "Keep this synthetic note" "$(cat "${MEM_DIR}/${today}.md")"
  assert_contains "unrelated access-log row survives" "${keep_mid}" "$(cat "${MEM_DIR}/.access_log")"
  assert_contains "unrelated backup note survives untouched" "Keep this synthetic note" "$(cat "${snap}/decisions/keep.md")"
  assert_file_absent "backup note of the forgotten id removed" "${snap}/decisions/erase.md"
  assert_file_absent "stale backup index removed" "${snap}/index.md"
  local newest_backup
  newest_backup="$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  assert_eq "forget itself wrote no new backup" "${snap}" "${newest_backup}"
}

# REGRESSION: cleanup must be keyed on the exact memory id. A memory whose TEXT merely overlaps with the forgotten one
# (it even contains the forget pattern inside derived artifacts of a DIFFERENT id) must survive everywhere.
test_forget_is_precise_for_overlapping_memories() {
  echo "=== test_forget_is_precise_for_overlapping_memories ==="
  setup
  "${BIN}" remember "Project Orchid budget" >/dev/null 2>&1
  "${BIN}" remember "Project Orchid budget review notes" >/dev/null 2>&1
  "${BIN}" learn score >/dev/null 2>&1

  local today short_mid long_mid
  today="$(date +%Y-%m-%d)"
  short_mid="$(extract_mid "$(grep -F -- 'Project Orchid budget' "${MEM_DIR}/${today}.md" | grep -v -F 'review' | head -n 1)")"
  long_mid="$(_mid_of 'Project Orchid budget review notes')"
  assert_eq "two distinct ids" "yes" "$([[ -n "${short_mid}" && -n "${long_mid}" && "${short_mid}" != "${long_mid}" ]] && echo yes || echo no)"

  # Derived artifacts of the SURVIVING memory deliberately contain the forget pattern as text.
  printf '%s\t%s\t%s\t%s\n' "1700000002" "reinforce" "${short_mid}" "compare with Project Orchid budget review notes" >> "${MEM_DIR}/.access_log"
  printf '%s\t%s\t%s\t%s\n' "1700000003" "reinforce" "${long_mid}" "Project Orchid budget review notes" >> "${MEM_DIR}/.access_log"
  local snap="${BACKUP_DIR}/vault-20000102-000000"
  mkdir -p "${snap}/decisions"
  printf '%s\n' '---' "memory_id: ${short_mid}" '---' '- Project Orchid budget (see also: Project Orchid budget review notes)' > "${snap}/decisions/short.md"
  printf '%s\n' '---' "memory_id: ${long_mid}" '---' '- Project Orchid budget review notes' > "${snap}/decisions/long.md"

  "${BIN}" forget "Project Orchid budget review notes" >/dev/null 2>&1

  local day scores log
  day="$(cat "${MEM_DIR}/${today}.md")"
  scores="$(cat "${MEM_DIR}/.scores")"
  log="$(cat "${MEM_DIR}/.access_log")"
  assert_contains "overlapping shorter memory survives in the day-file" "Project Orchid budget" "${day}"
  assert_not_contains "forgotten longer memory left the day-file" "review notes" "${day}"
  assert_contains "surviving id keeps its score row" "${short_mid}" "${scores}"
  assert_not_contains "forgotten id left the scores" "${long_mid}" "${scores}"
  assert_contains "surviving id keeps its access-log row even though its snippet contains the pattern" "${short_mid}" "${log}"
  assert_not_contains "forgotten id left the access log" "${long_mid}" "${log}"
  assert_contains "backup note of the surviving id is untouched although it contains the pattern text" "see also" "$(cat "${snap}/decisions/short.md")"
  assert_file_absent "backup note of the forgotten id removed" "${snap}/decisions/long.md"
}

# Normal lifecycle: day-files are append-only. None of the learning operations may rewrite them.
test_lifecycle_never_rewrites_dayfiles() {
  echo "=== test_lifecycle_never_rewrites_dayfiles ==="
  setup
  "${BIN}" remember "Lifecycle synthetic note one" >/dev/null 2>&1
  "${BIN}" remember "Lifecycle synthetic note two" >/dev/null 2>&1
  local today before after op
  today="$(date +%Y-%m-%d)"
  before="$(cksum < "${MEM_DIR}/${today}.md")"
  for op in score reinforce decay consolidate promote prune cycle; do
    if [[ "${op}" == "reinforce" ]]; then
      "${BIN}" learn reinforce "Lifecycle synthetic" >/dev/null 2>&1 || true
    else
      "${BIN}" learn "${op}" >/dev/null 2>&1 || true
    fi
    after="$(cksum < "${MEM_DIR}/${today}.md")"
    assert_eq "learn ${op} does not rewrite the day-file" "${before}" "${after}"
  done
}

test_recall_vault() {
  echo "=== test_recall_vault ==="
  setup
  "${BIN}" remember "Vault recall test item" >/dev/null 2>&1

  local out
  out="$("${BIN}" recall "recall test" 2>&1)"
  assert_contains "recall finds vault match" "recall test" "${out}"
  assert_contains "recall file count" "file(s) matched" "${out}"
}

test_recall_dayfile_fallback() {
  echo "=== test_recall_dayfile_fallback ==="
  setup
  # Write to day-file directly without syncing to vault
  local today
  today="$(date +%Y-%m-%d)"
  local day_file="${MEM_DIR}/${today}.md"
  cat > "${day_file}" <<EOF
# ${today}

## Decisions
- Unique fallback search term XYZ123
EOF

  local out
  out="$("${BIN}" recall "XYZ123" 2>&1)"
  assert_contains "recall falls back to day-files" "Day-file matches" "${out}"
  assert_contains "recall finds day-file match" "XYZ123" "${out}"
}

test_score() {
  echo "=== test_score ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: adopt TrustMem

## Preferences
- Prefer dark mode
EOF

  local out
  out="$("${BIN}" learn score 2>&1)"
  assert_contains "score output" "score: ok" "${out}"
  assert_contains "new entries scored" "new_entries: 2" "${out}"

  # Decisions get weight 100 -> score 50; Preferences get weight 90 -> score 45
  local scores_content
  scores_content="$(cat "${MEM_DIR}/.scores")"
  assert_contains "scores file populated" "Decision: adopt TrustMem" "${scores_content}"
  assert_contains "scores file has preferences" "Prefer dark mode" "${scores_content}"

  local decision_score
  decision_score="$(awk -F'\t' '$6 == "Decision: adopt TrustMem" { print $2 }' "${MEM_DIR}/.scores")"
  assert_eq "decision weighted score" "50" "${decision_score}"
  local preference_score
  preference_score="$(awk -F'\t' '$6 == "Prefer dark mode" { print $2 }' "${MEM_DIR}/.scores")"
  assert_eq "preference weighted score" "45" "${preference_score}"

  # Re-scoring is idempotent: stable mids mean no duplicate rows.
  out="$("${BIN}" learn score 2>&1)"
  assert_contains "rescore finds no new entries" "new_entries: 0" "${out}"
  assert_contains "rescore sees existing entries" "existing_entries: 2" "${out}"
}

test_reinforce() {
  echo "=== test_reinforce ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: use SQLite
EOF

  "${BIN}" learn score >/dev/null 2>&1

  local out
  out="$("${BIN}" learn reinforce "SQLite" 2>&1)"
  assert_contains "reinforce output" "reinforce: ok" "${out}"
  assert_contains "boosted count" "boosted: 1" "${out}"

  local new_score
  new_score="$(cut -f2 "${MEM_DIR}/.scores")"
  if [[ "${new_score}" -gt 50 ]]; then
    pass=$((pass + 1))
    printf '  PASS  reinforced score rose from 50 to %s\n' "${new_score}"
  else
    fail=$((fail + 1))
    printf '  FAIL  reinforced score should have risen (got %s)\n' "${new_score}"
  fi

  local reinforcements
  reinforcements="$(cut -f5 "${MEM_DIR}/.scores")"
  assert_eq "reinforcement counter incremented" "1" "${reinforcements}"
  assert_file_exists "access log written" "${MEM_DIR}/.access_log"
}

test_decay() {
  echo "=== test_decay ==="
  setup
  # Create a scores file with an entry created >90 days ago (outside general
  # retention) and last accessed 10 days ago.
  local now
  now="$(date +%s)"
  local old_access=$(( now - 864000 ))   # 10 days ago
  local old_create=$(( now - 8640000 ))  # 100 days ago (exceeds 90-day general retention)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "abcdef0123456789" "50" "${old_access}" "${old_create}" "0" "Old stale entry" "general" \
    > "${MEM_DIR}/.scores"
  touch "${MEM_DIR}/.access_log"

  local out
  out="$("${BIN}" learn decay 2>&1)"
  assert_contains "decay output" "decay: ok" "${out}"
  assert_contains "decayed entries" "decayed_entries: 1" "${out}"

  # Score should have dropped from 50
  local new_score
  new_score="$(cut -f2 "${MEM_DIR}/.scores")"
  if [[ "${new_score}" -lt 50 ]]; then
    pass=$((pass + 1))
    printf '  PASS  score decayed from 50 to %s\n' "${new_score}"
  else
    fail=$((fail + 1))
    printf '  FAIL  score should have decayed (got %s)\n' "${new_score}"
  fi
}

test_decay_category_retention() {
  echo "=== test_decay_category_retention ==="
  setup
  # A "decisions" entry (365-day retention) accessed recently.
  local now
  now="$(date +%s)"
  local recent_ts=$(( now - 86400 ))  # 1 day ago
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "decisionentry001" "50" "${recent_ts}" "${now}" "0" "Important decision" "decisions" \
    > "${MEM_DIR}/.scores"
  touch "${MEM_DIR}/.access_log"

  local out
  out="$("${BIN}" learn decay 2>&1)"
  assert_contains "decay respects retention" "retained_by_policy: 1" "${out}"

  # Score should NOT have changed because entry is within retention
  local new_score
  new_score="$(cut -f2 "${MEM_DIR}/.scores")"
  assert_eq "decision score unchanged" "50" "${new_score}"
}

test_consolidate() {
  echo "=== test_consolidate ==="
  setup
  local now
  now="$(date +%s)"
  # Duplicate entries with the same snippet; the higher score must survive.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "aaaa000000000001" "50" "${now}" "${now}" "0" "Duplicate entry" "general" \
    "bbbb000000000002" "60" "${now}" "${now}" "0" "Duplicate entry" "general" \
    > "${MEM_DIR}/.scores"
  touch "${MEM_DIR}/.access_log"

  local out
  out="$("${BIN}" learn consolidate 2>&1)"
  assert_contains "consolidate output" "consolidate: ok" "${out}"
  assert_contains "duplicates found" "duplicates_removed: 1" "${out}"

  local remaining
  remaining="$(wc -l < "${MEM_DIR}/.scores" | tr -d ' ')"
  assert_eq "one entry remains" "1" "${remaining}"

  local surviving_score
  surviving_score="$(cut -f2 "${MEM_DIR}/.scores")"
  assert_eq "higher-scored duplicate survived" "60" "${surviving_score}"
}

test_promote() {
  echo "=== test_promote ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: test promote flow
EOF

  "${BIN}" learn score >/dev/null 2>&1

  local out
  out="$("${BIN}" learn promote 2>&1)"
  assert_contains "promote output" "promote: ok" "${out}"
  assert_contains "promoted entries" "promoted_entries: 1" "${out}"
  assert_file_exists "promotion manifest written" "${MEM_DIR}/.promoted"

  # Promotion is idempotent.
  out="$("${BIN}" learn promote 2>&1)"
  assert_contains "already-promoted entry not re-promoted" "promoted_entries: 0" "${out}"
}

test_promote_threshold() {
  echo "=== test_promote_threshold ==="
  setup
  local now
  now="$(date +%s)"
  # score 5 is below PROMOTE_THRESHOLD (40) and must not be promoted.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "cccc000000000003" "5" "${now}" "${now}" "0" "Weak entry" "general" \
    > "${MEM_DIR}/.scores"
  touch "${MEM_DIR}/.access_log"

  local out
  out="$("${BIN}" learn promote 2>&1)"
  assert_contains "below-threshold entry not promoted" "promoted_entries: 0" "${out}"
}

test_prune() {
  echo "=== test_prune ==="
  setup
  local now
  now="$(date +%s)"
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- [mid:abcd000000000001] [09:00:00] Should be pruned
EOF
  printf '%s\t%s\t%s\n' "abcd000000000001" "${today}.md" "$(date -Iseconds)" > "${MEM_DIR}/.promoted"
  "${BIN}" sync >/dev/null 2>&1
  # An entry below the prune threshold (score=5, threshold=10).
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "abcd000000000001" "5" "${now}" "${now}" "0" "Should be pruned" "general" \
    > "${MEM_DIR}/.scores"
  touch "${MEM_DIR}/.access_log"

  local out
  out="$("${BIN}" learn prune 2>&1)"
  assert_contains "prune output" "prune: ok" "${out}"
  assert_contains "pruned entries" "pruned_entries: 1" "${out}"
  assert_contains "prune names its mode" "prune_mode: score-threshold" "${out}"
  assert_contains "prune reports day-files untouched" "day_files_modified: 0" "${out}"

  local remaining
  remaining="$(wc -l < "${MEM_DIR}/.scores" | tr -d ' ')"
  assert_eq "scores file empty after prune" "0" "${remaining}"

  # The day-file is the audit trail: score-based prune must never edit it.
  local day_content
  day_content="$(cat "${MEM_DIR}/${today}.md")"
  assert_contains "day-file entry survives a score-based prune" "Should be pruned" "${day_content}"

  local promoted_content
  promoted_content="$(cat "${MEM_DIR}/.promoted")"
  assert_not_contains "pruned mid removed from manifest" "abcd000000000001" "${promoted_content}"

  local vault_content
  vault_content="$(find "${VAULT_DIR}" -type f -name '*.md' -exec cat {} +)"
  assert_not_contains "pruned vault entry removed" "Should be pruned" "${vault_content}"
  assert_file_absent "prune created no stale vault backup" "${BACKUP_DIR}"
}

test_prune_scores_alias() {
  echo "=== test_prune_scores_alias ==="
  setup
  local out
  out="$("${BIN}" learn prune-scores 2>&1)"
  assert_contains "prune-scores alias runs the score-based prune" "prune_mode: score-threshold" "${out}"
}

test_cycle() {
  echo "=== test_cycle ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: full cycle test
- Decision: another test

## Preferences
- Prefer light theme
EOF

  local out
  out="$("${BIN}" learn cycle 2>&1)"
  assert_contains "cycle runs score" "── score ──" "${out}"
  assert_contains "cycle runs decay" "── decay ──" "${out}"
  assert_contains "cycle runs consolidate" "── consolidate ──" "${out}"
  assert_contains "cycle runs promote" "── promote ──" "${out}"
  assert_contains "cycle runs prune" "── prune ──" "${out}"
  assert_contains "cycle runs status" "── status ──" "${out}"
  assert_contains "cycle reports total" "total_entries:" "${out}"
}

test_status() {
  echo "=== test_status ==="
  setup
  local now
  now="$(date +%s)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "dddd000000000004" "80" "${now}" "${now}" "2" "High confidence entry" "decisions" \
    "eeee000000000005" "45" "${now}" "${now}" "0" "Medium confidence entry" "general" \
    > "${MEM_DIR}/.scores"
  touch "${MEM_DIR}/.access_log"

  local out
  out="$("${BIN}" learn status 2>&1)"
  assert_contains "status totals" "total_entries: 2" "${out}"
  assert_contains "status high confidence" "high_confidence: 1" "${out}"
  assert_contains "status medium confidence" "medium_confidence: 1" "${out}"
  assert_contains "status reinforcements" "total_reinforcements: 2" "${out}"
  assert_contains "status thresholds" "prune_threshold: 10" "${out}"
}

test_sync() {
  echo "=== test_sync ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: we chose Markdown vaults

## Open TODOs
- TODO: ship v1
EOF

  "${BIN}" sync --init-promoted >/dev/null 2>&1
  local out
  out="$("${BIN}" sync 2>&1)"
  assert_contains "sync output" "vault_sync: ok" "${out}"

  assert_file_exists "vault index created" "${VAULT_DIR}/index.md"
  local index_content
  index_content="$(cat "${VAULT_DIR}/index.md")"
  assert_contains "index has decisions" "Decisions" "${index_content}"
  assert_contains "index has commitments" "Commitments" "${index_content}"

  local vault_content
  vault_content="$(find "${VAULT_DIR}" -type f -name '*.md' -exec cat {} +)"
  assert_contains "generated note carries a memory_id" "memory_id" "${vault_content}"
}

test_sync_promotion_filter() {
  echo "=== test_sync_promotion_filter ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- [mid:1111000000000001] [09:00:00] Decision: promoted item
- [mid:2222000000000002] [09:01:00] Decision: unpromoted item
EOF
  printf '%s\t%s\t%s\n' "1111000000000001" "${today}.md" "$(date -Iseconds)" > "${MEM_DIR}/.promoted"

  "${BIN}" sync >/dev/null 2>&1
  local vault_content
  vault_content="$(find "${VAULT_DIR}" -type f -name '*.md' -exec cat {} +)"
  assert_contains "promoted line materialized" "Decision: promoted item" "${vault_content}"
  assert_not_contains "unpromoted line withheld" "Decision: unpromoted item" "${vault_content}"
}

test_scopes_require_configuration() {
  echo "=== test_scopes_require_configuration ==="
  setup
  # No scope map: no built-in project or person tables may invent notes.
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: Widget Factory and Ada Fixture agreed on the schedule
EOF

  "${BIN}" sync --init-promoted >/dev/null 2>&1
  local out
  out="$("${BIN}" sync 2>&1)"
  assert_contains "no projects without a scope map" "projects: 0" "${out}"
  assert_contains "no people without a scope map" "people: 0" "${out}"
}

test_project_scoping() {
  echo "=== test_project_scoping ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: Widget Factory ships on Friday
EOF

  "${BIN}" sync --init-promoted >/dev/null 2>&1
  local out
  out="$(PROJECT_MAP_FILE="${FIXTURES}/projects-map.test.yaml" "${BIN}" sync 2>&1)"
  assert_contains "configured project matched" "projects: 1" "${out}"
  assert_file_exists "project note written" "${VAULT_DIR}/projects/widget-factory.md"

  local note
  note="$(cat "${VAULT_DIR}/projects/widget-factory.md")"
  assert_contains "project note titled from the map" "# Widget Factory" "${note}"
  assert_contains "project note records the fact" "ships on Friday" "${note}"
  assert_contains "project note carries memory_ids" "memory_ids:" "${note}"
  assert_contains "project_id from the active policy" "project_id: example-project" "${note}"

  # An explicit project id overrides the policy value.
  TRUSTMEM_PROJECT_ID="override-id" PROJECT_MAP_FILE="${FIXTURES}/projects-map.test.yaml" \
    "${BIN}" sync --rebuild --no-backup >/dev/null 2>&1
  note="$(cat "${VAULT_DIR}/projects/widget-factory.md")"
  assert_contains "TRUSTMEM_PROJECT_ID overrides the policy" "project_id: override-id" "${note}"
}

test_person_scoping() {
  echo "=== test_person_scoping ==="
  setup
  local today
  today="$(date +%Y-%m-%d)"
  cat > "${MEM_DIR}/${today}.md" <<EOF
# ${today}

## Decisions
- Decision: Ada Fixture approved the rollout
- Decision: ping @testhandle before the release
- Decision: the @widget integration is done
EOF

  "${BIN}" sync --init-promoted >/dev/null 2>&1
  PROJECT_MAP_FILE="${FIXTURES}/projects-map.test.yaml" "${BIN}" sync >/dev/null 2>&1

  assert_file_exists "configured bare name becomes a person note" "${VAULT_DIR}/people/ada-fixture.md"
  assert_file_exists "unknown handle becomes a person note" "${VAULT_DIR}/people/testhandle.md"
  assert_file_absent "excluded handle creates no person note" "${VAULT_DIR}/people/widget.md"

  local note
  note="$(cat "${VAULT_DIR}/people/ada-fixture.md")"
  assert_contains "person note titled from the map" "# Ada Fixture" "${note}"
}

test_doctor() {
  echo "=== test_doctor ==="
  setup
  local out
  out="$("${BIN}" doctor 2>&1)"
  assert_contains "doctor checks binaries" "binary present: awk" "${out}"
  assert_contains "doctor checks files" "file present:" "${out}"
  assert_contains "doctor checks lib.sh" "lib.sh" "${out}"
  assert_contains "doctor checks scores" "scores file" "${out}"
  assert_contains "doctor checks vault" "vault" "${out}"
  assert_contains "doctor reports the active policy" "active policy:" "${out}"
  assert_contains "doctor reports the policy project id" "example-project" "${out}"
  assert_contains "doctor notes the missing scope map" "scoping are disabled" "${out}"
}

test_lib_functions() {
  echo "=== test_lib_functions ==="
  # shellcheck source=scripts/lib.sh
  source "${TRUSTMEM_DIR}/scripts/lib.sh"

  # extract_mid
  local mid
  mid="$(extract_mid "- [mid:abcdef0123456789] Hello")"
  assert_eq "extract_mid basic" "abcdef0123456789" "${mid}"

  mid="$(extract_mid "No mid here")"
  assert_eq "extract_mid missing" "" "${mid}"

  # strip_mid
  local stripped
  stripped="$(strip_mid "[mid:abcdef0123456789] Hello world")"
  assert_eq "strip_mid" "Hello world" "${stripped}"

  # clean_line
  local cleaned
  cleaned="$(clean_line "- [09:15:00] A tidy line")"
  assert_eq "clean_line strips bullet and stamp" "A tidy line" "${cleaned}"

  # derive_mid_from_content — stable across calls
  local derived derived_again
  derived="$(derive_mid_from_content "test content")"
  derived_again="$(derive_mid_from_content "test content")"
  assert_eq "derive_mid length" "16" "${#derived}"
  assert_eq "derive_mid is stable" "${derived}" "${derived_again}"

  # slugify
  local slug
  slug="$(slugify "Hello World! Test")"
  assert_eq "slugify" "hello-world-test" "${slug}"

  slug="$(slugify "")"
  assert_eq "slugify empty" "item" "${slug}"

  # regex_escape
  local escaped
  escaped="$(regex_escape "a.b*c")"
  assert_eq "regex_escape" 'a\.b\*c' "${escaped}"

  # resolve_policy_path — configurable profile, explicit override wins
  local resolved
  resolved="$(POLICY_FILE="" resolve_policy_path "/opt/tm" "")"
  assert_eq "policy defaults to the example profile" "/opt/tm/policies/example-memory-policy.yaml" "${resolved}"
  resolved="$(POLICY_FILE="" resolve_policy_path "/opt/tm" "acme")"
  assert_eq "policy honours a named profile" "/opt/tm/policies/acme-memory-policy.yaml" "${resolved}"
  resolved="$(POLICY_FILE="/etc/tm/custom.yaml" resolve_policy_path "/opt/tm" "acme")"
  assert_eq "explicit POLICY_FILE wins" "/etc/tm/custom.yaml" "${resolved}"

  # policy_project_id — read from the policy, no built-in default
  local project_id
  project_id="$(policy_project_id "${TRUSTMEM_DIR}/policies/example-memory-policy.yaml")"
  assert_eq "project id from the shipped policy" "example-project" "${project_id}"
  project_id="$(policy_project_id "${FIXTURES}/strict-memory-policy.yaml")"
  assert_eq "project id from an alternate policy" "fixture-project" "${project_id}"
  project_id="$(policy_project_id "/nonexistent/policy.yaml")"
  assert_eq "project id empty when no policy" "" "${project_id}"

  # category_weight
  local w
  w="$(category_weight "decisions")"
  assert_eq "category_weight decisions" "100" "${w}"
  w="$(category_weight "preferences")"
  assert_eq "category_weight preferences" "90" "${w}"
  w="$(category_weight "constraints")"
  assert_eq "category_weight constraints" "85" "${w}"
  w="$(category_weight "open todos")"
  assert_eq "category_weight todos" "80" "${w}"

  # category_retention_days
  local r
  r="$(category_retention_days "decisions")"
  assert_eq "retention decisions" "365" "${r}"
  r="$(category_retention_days "preferences")"
  assert_eq "retention preferences" "3650" "${r}"
  r="$(category_retention_days "open todos")"
  assert_eq "retention todos" "90" "${r}"

  # Generated notes are scrubbed before a rebuild, so failure to rebuild cannot
  # leave the forgotten content searchable in the vault.
  setup
  mkdir -p "${VAULT_DIR}/decisions"
  printf '%s\n' 'memory_id: abcd000000000002' > "${VAULT_DIR}/decisions/drop.md"
  printf '%s\n' 'stale index text' > "${VAULT_DIR}/index.md"
  printf '%s\n' 'unrelated note' > "${VAULT_DIR}/decisions/keep.md"
  scrub_vault_memory_ids "abcd000000000002"
  if [[ ! -f "${VAULT_DIR}/decisions/drop.md" && ! -f "${VAULT_DIR}/index.md" && -f "${VAULT_DIR}/decisions/keep.md" ]]; then
    pass=$((pass + 1))
    printf '  PASS  scrub_vault_memory_ids removes only generated matches + index\n'
  else
    fail=$((fail + 1))
    printf '  FAIL  scrub_vault_memory_ids result was inconsistent\n'
  fi
}

test_repository_is_generic() {
  echo "=== test_repository_is_generic ==="
  # Only the generic example profile may be shipped: a downstream profile must
  # never be committed, and nothing in the tree may point at one by name.
  local policies
  policies="$(find "${TRUSTMEM_DIR}/policies" -maxdepth 1 -type f -name '*.yaml' -exec basename {} \; | sort | tr '\n' ' ')"
  assert_eq "policies/ ships only the example profile" "example-memory-policy.yaml " "${policies}"

  local stray
  stray="$(rg -o --no-filename --glob '!**/.git/**' --glob '!**/tests/**' --glob '!**/policies/**' \
    -- '[A-Za-z0-9_]+-memory-policy\.yaml' "${TRUSTMEM_DIR}" 2>/dev/null \
    | sort -u | rg -v '^example-memory-policy\.yaml$' || true)"
  assert_eq "no reference to a non-example policy profile" "" "${stray}"

  assert_file_exists "generic example policy shipped" "${TRUSTMEM_DIR}/policies/example-memory-policy.yaml"
}

# ── Run all tests ────────────────────────────────────────────────────

echo "TrustMem test suite"
echo "==================="
echo ""

test_version
test_lib_functions
test_remember
test_policy_block
test_full_transcript_block
test_policy_profile_is_configurable
test_ingest
test_forget
test_forget_leaves_no_recoverable_copy
test_forget_is_precise_for_overlapping_memories
test_lifecycle_never_rewrites_dayfiles
test_recall_vault
test_recall_dayfile_fallback
test_score
test_reinforce
test_decay
test_decay_category_retention
test_consolidate
test_promote
test_promote_threshold
test_prune
test_prune_scores_alias
test_cycle
test_status
test_sync
test_sync_promotion_filter
test_scopes_require_configuration
test_project_scoping
test_person_scoping
test_doctor
test_repository_is_generic

echo ""
echo "==================="
printf 'Results: %s passed, %s failed\n' "${pass}" "${fail}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
