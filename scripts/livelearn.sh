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

SCORES_FILE="${MEM_DIR}/.scores"
ACCESS_LOG="${MEM_DIR}/.access_log"
PROMOTED_FILE="${MEM_DIR}/.promoted"

INITIAL_SCORE="${INITIAL_SCORE:-50}"
REINFORCE_PCT="${REINFORCE_PCT:-15}"
DECAY_PCT="${DECAY_PCT:-3}"
PRUNE_THRESHOLD="${PRUNE_THRESHOLD:-10}"
PROMOTE_THRESHOLD="${PROMOTE_THRESHOLD:-40}"

# ── Helpers ──────────────────────────────────────────────────────────

usage() {
  cat <<'USAGE'
Usage:
  livelearn.sh score              Compute scores for all memory entries
  livelearn.sh reinforce "<pat>"  Boost entries matching pattern
  livelearn.sh decay              Apply time-based decay to all scores
  livelearn.sh consolidate        Flag duplicate memory entries in scores
  livelearn.sh promote            Promote above-threshold entries to vault
  livelearn.sh prune              Remove below-threshold entries from scores + promoted
  livelearn.sh status             Show learning metrics
  livelearn.sh cycle              Run full cycle (score+decay+consolidate+promote+prune)
USAGE
}

ensure_paths() {
  mkdir -p "${MEM_DIR}"
  touch "${SCORES_FILE}" "${ACCESS_LOG}"
}

epoch_now() {
  date +%s
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

clean_line() {
  printf '%s' "$1" | sed -E 's/^- +//; s/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] +//'
}

derive_mid_from_content() {
  printf '%s' "$1" | sha1sum | cut -c1-16
}

calculate_boost() {
  local score="$1" pct="$2"
  local boost=$(( (100 - score) * pct / 100 ))
  if [[ "${boost}" -lt 1 ]]; then boost=1; fi
  printf '%s' "${boost}"
}

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

log_access() {
  local action="$1" mid="$2" snippet="$3"
  printf '%s\t%s\t%s\t%s\n' "$(epoch_now)" "${action}" "${mid}" "${snippet}" >> "${ACCESS_LOG}"
}

# ── Batch score storage ──────────────────────────────────────────────
# Format: mid \t score \t last_accessed \t created \t reinforcements \t snippet
# All mutations happen in-memory via associative arrays; flushed once at end.

declare -A SC_SCORE SC_ACCESSED SC_CREATED SC_REINFORCEMENTS SC_SNIPPET
SCORES_DIRTY=false

load_scores() {
  while IFS=$'\t' read -r mid score accessed created reinforcements snippet; do
    if [[ -z "${mid}" ]]; then continue; fi
    SC_SCORE["${mid}"]="${score}"
    SC_ACCESSED["${mid}"]="${accessed}"
    SC_CREATED["${mid}"]="${created}"
    SC_REINFORCEMENTS["${mid}"]="${reinforcements}"
    SC_SNIPPET["${mid}"]="${snippet}"
  done < "${SCORES_FILE}"
}

flush_scores() {
  if [[ "${SCORES_DIRTY}" != "true" ]]; then return; fi
  local tmp="${SCORES_FILE}.tmp"
  : > "${tmp}"
  for mid in "${!SC_SCORE[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${mid}" "${SC_SCORE[${mid}]}" "${SC_ACCESSED[${mid}]}" \
      "${SC_CREATED[${mid}]}" "${SC_REINFORCEMENTS[${mid}]}" \
      "${SC_SNIPPET[${mid}]}" >> "${tmp}"
  done
  mv "${tmp}" "${SCORES_FILE}"
}

set_score() {
  local mid="$1" score="$2" accessed="$3" created="$4" reinforcements="$5" snippet="$6"
  SC_SCORE["${mid}"]="${score}"
  SC_ACCESSED["${mid}"]="${accessed}"
  SC_CREATED["${mid}"]="${created}"
  SC_REINFORCEMENTS["${mid}"]="${reinforcements}"
  SC_SNIPPET["${mid}"]="${snippet}"
  SCORES_DIRTY=true
}

delete_score() {
  local mid="$1"
  unset SC_SCORE["${mid}"] SC_ACCESSED["${mid}"] SC_CREATED["${mid}"] \
        SC_REINFORCEMENTS["${mid}"] SC_SNIPPET["${mid}"]
  SCORES_DIRTY=true
}

# ── Subcommands ──────────────────────────────────────────────────────

cmd_score() {
  ensure_paths
  load_scores
  local added=0 updated=0
  local now
  now="$(epoch_now)"

  while IFS= read -r file; do
    local section=""
    while IFS= read -r raw_line; do
      if [[ "${raw_line}" =~ ^##[[:space:]]+(.+)$ ]]; then
        section="${BASH_REMATCH[1]}"
        continue
      fi
      if [[ -z "${raw_line}" || "${raw_line}" == \#* ]]; then
        continue
      fi

      local mid
      mid="$(extract_mid "${raw_line}")"
      local cleaned
      cleaned="$(clean_line "$(strip_mid "${raw_line}")")"
      if [[ -z "${cleaned}" ]]; then continue; fi

      if [[ -z "${mid}" ]]; then
        mid="$(derive_mid_from_content "${cleaned}")"
      fi

      if [[ -z "${SC_SCORE[${mid}]+_}" ]]; then
        local weight
        weight="$(category_weight "${section}")"
        local weighted_score=$(( INITIAL_SCORE * weight / 100 ))
        set_score "${mid}" "${weighted_score}" "${now}" "${now}" "0" "${cleaned:0:120}"
        added=$((added + 1))
      else
        updated=$((updated + 1))
      fi
    done < "${file}"
  done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" | sort)

  flush_scores
  echo "score: ok"
  echo "new_entries: ${added}"
  echo "existing_entries: ${updated}"
}

cmd_reinforce() {
  ensure_paths
  load_scores
  local pattern="$1"
  local boosted=0
  local now
  now="$(epoch_now)"

  for mid in "${!SC_SCORE[@]}"; do
    if printf '%s\n' "${SC_SNIPPET[${mid}]}" | rg -Fqi -- "${pattern}"; then
      local score="${SC_SCORE[${mid}]}"
      local boost
      boost="$(calculate_boost "${score}" "${REINFORCE_PCT}")"
      local new_score=$(( score + boost ))
      if [[ "${new_score}" -gt 100 ]]; then new_score=100; fi
      set_score "${mid}" "${new_score}" "${now}" "${SC_CREATED[${mid}]}" \
        "$(( SC_REINFORCEMENTS[${mid}] + 1 ))" "${SC_SNIPPET[${mid}]}"
      log_access "reinforce" "${mid}" "${SC_SNIPPET[${mid}]}"
      boosted=$((boosted + 1))
    fi
  done

  flush_scores
  echo "reinforce: ok"
  echo "boosted: ${boosted}"
}

cmd_decay() {
  ensure_paths
  load_scores
  local decayed=0
  local now
  now="$(epoch_now)"

  for mid in "${!SC_SCORE[@]}"; do
    local score="${SC_SCORE[${mid}]}"
    local accessed="${SC_ACCESSED[${mid}]}"
    local age_seconds=$(( now - accessed ))
    local age_days=$(( age_seconds / 86400 ))

    if [[ "${age_days}" -gt 0 ]]; then
      local new_score="${score}"
      local i=0
      while [[ "${i}" -lt "${age_days}" ]]; do
        new_score=$(( new_score * (100 - DECAY_PCT) / 100 ))
        i=$((i + 1))
      done
      if [[ "${new_score}" -ne "${score}" ]]; then
        set_score "${mid}" "${new_score}" "${accessed}" "${SC_CREATED[${mid}]}" \
          "${SC_REINFORCEMENTS[${mid}]}" "${SC_SNIPPET[${mid}]}"
        decayed=$((decayed + 1))
      fi
    fi
  done

  flush_scores
  echo "decay: ok"
  echo "decayed_entries: ${decayed}"
}

cmd_consolidate() {
  ensure_paths
  load_scores
  local flagged=0

  declare -A seen_snippets
  for mid in "${!SC_SCORE[@]}"; do
    local snippet="${SC_SNIPPET[${mid}]}"
    local snip_hash
    snip_hash="$(derive_mid_from_content "${snippet}")"
    if [[ -n "${seen_snippets[${snip_hash}]+_}" ]]; then
      local existing_mid="${seen_snippets[${snip_hash}]}"
      local existing_score="${SC_SCORE[${existing_mid}]}"
      local this_score="${SC_SCORE[${mid}]}"
      if [[ "${this_score}" -gt "${existing_score}" ]]; then
        delete_score "${existing_mid}"
        seen_snippets["${snip_hash}"]="${mid}"
      else
        delete_score "${mid}"
      fi
      flagged=$((flagged + 1))
    else
      seen_snippets["${snip_hash}"]="${mid}"
    fi
  done

  flush_scores
  echo "consolidate: ok"
  echo "duplicates_removed: ${flagged}"
}

cmd_promote() {
  ensure_paths
  load_scores
  local promoted=0

  declare -A already_promoted
  if [[ -f "${PROMOTED_FILE}" ]]; then
    while IFS=$'\t' read -r mid _rest; do
      if [[ -n "${mid}" ]]; then
        already_promoted["${mid}"]=1
      fi
    done < "${PROMOTED_FILE}"
  fi

  local ts
  ts="$(date -Iseconds)"

  for mid in "${!SC_SCORE[@]}"; do
    local score="${SC_SCORE[${mid}]}"
    if [[ "${score}" -ge "${PROMOTE_THRESHOLD}" && -z "${already_promoted[${mid}]+_}" ]]; then
      printf '%s\t%s\t%s\n' "${mid}" "scored" "${ts}" >> "${PROMOTED_FILE}"
      log_access "promote" "${mid}" "${SC_SNIPPET[${mid}]}"
      promoted=$((promoted + 1))
    fi
  done

  echo "promote: ok"
  echo "promoted_entries: ${promoted}"

  if [[ "${promoted}" -gt 0 ]]; then
    echo "Running vault_sync..."
    if [[ -x "${VAULT_SYNC_SCRIPT}" ]]; then
      "${VAULT_SYNC_SCRIPT}"
    fi
  fi
}

cmd_prune() {
  ensure_paths
  load_scores
  local pruned=0
  local pruned_mids=""

  for mid in "${!SC_SCORE[@]}"; do
    local score="${SC_SCORE[${mid}]}"
    if [[ "${score}" -lt "${PRUNE_THRESHOLD}" ]]; then
      log_access "prune" "${mid}" "${SC_SNIPPET[${mid}]}"
      delete_score "${mid}"
      pruned_mids="${pruned_mids}${mid}"$'\n'
      pruned=$((pruned + 1))
    fi
  done

  flush_scores

  if [[ -n "${pruned_mids}" && -f "${PROMOTED_FILE}" ]]; then
    local tmp="${PROMOTED_FILE}.tmp"
    cp "${PROMOTED_FILE}" "${tmp}"
    while IFS= read -r mid; do
      if [[ -n "${mid}" ]]; then
        local filtered="${tmp}.f"
        rg -v --fixed-strings -- "${mid}" "${tmp}" > "${filtered}" 2>/dev/null || true
        mv "${filtered}" "${tmp}"
      fi
    done <<< "${pruned_mids}"
    mv "${tmp}" "${PROMOTED_FILE}"
  fi

  echo "prune: ok"
  echo "pruned_entries: ${pruned}"
}

cmd_status() {
  ensure_paths
  load_scores
  local total=0 high=0 medium=0 low=0 critical=0
  local max_score=0 min_score=100 sum=0
  local total_reinforcements=0

  for mid in "${!SC_SCORE[@]}"; do
    local score="${SC_SCORE[${mid}]}"
    local reinforcements="${SC_REINFORCEMENTS[${mid}]}"
    total=$((total + 1))
    sum=$((sum + score))
    total_reinforcements=$((total_reinforcements + reinforcements))
    if [[ "${score}" -gt "${max_score}" ]]; then max_score="${score}"; fi
    if [[ "${score}" -lt "${min_score}" ]]; then min_score="${score}"; fi
    if [[ "${score}" -ge 75 ]]; then
      high=$((high + 1))
    elif [[ "${score}" -ge 40 ]]; then
      medium=$((medium + 1))
    elif [[ "${score}" -ge "${PRUNE_THRESHOLD}" ]]; then
      low=$((low + 1))
    else
      critical=$((critical + 1))
    fi
  done

  local avg=0
  if [[ "${total}" -gt 0 ]]; then
    avg=$(( sum / total ))
  else
    min_score=0
  fi

  local access_count=0
  if [[ -f "${ACCESS_LOG}" ]]; then
    access_count="$(wc -l < "${ACCESS_LOG}" | tr -d ' ')"
  fi

  local promoted_count=0
  if [[ -f "${PROMOTED_FILE}" ]]; then
    promoted_count="$(wc -l < "${PROMOTED_FILE}" | tr -d ' ')"
  fi

  echo "status: ok"
  echo "total_entries: ${total}"
  echo "avg_score: ${avg}"
  echo "max_score: ${max_score}"
  echo "min_score: ${min_score}"
  echo "high_confidence: ${high}"
  echo "medium_confidence: ${medium}"
  echo "low_confidence: ${low}"
  echo "below_threshold: ${critical}"
  echo "total_reinforcements: ${total_reinforcements}"
  echo "promoted_entries: ${promoted_count}"
  echo "access_log_entries: ${access_count}"
  echo "prune_threshold: ${PRUNE_THRESHOLD}"
  echo "promote_threshold: ${PROMOTE_THRESHOLD}"
}

cmd_cycle() {
  echo "── score ──"
  cmd_score
  echo ""
  echo "── decay ──"
  cmd_decay
  echo ""
  echo "── consolidate ──"
  cmd_consolidate
  echo ""
  echo "── promote ──"
  cmd_promote
  echo ""
  echo "── prune ──"
  cmd_prune
  echo ""
  echo "── status ──"
  cmd_status
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  local cmd="$1"
  shift

  case "${cmd}" in
    score)       cmd_score ;;
    reinforce)   cmd_reinforce "$*" ;;
    decay)       cmd_decay ;;
    consolidate) cmd_consolidate ;;
    promote)     cmd_promote ;;
    prune)       cmd_prune ;;
    status)      cmd_status ;;
    cycle)       cmd_cycle ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
