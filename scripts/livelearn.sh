#!/usr/bin/env bash
set -euo pipefail

# ── Continuous live-learning engine for TrustMem ──
# Scores, reinforces, decays, consolidates, and prunes memory entries
# so the vault improves over time without manual curation.

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

# Metadata files (local-only, gitignored via memory/)
SCORES_FILE="${MEM_DIR}/.scores"
ACCESS_LOG="${MEM_DIR}/.access_log"

# Tuning knobs (overridable via env)
INITIAL_SCORE="${INITIAL_SCORE:-50}"
REINFORCE_PCT="${REINFORCE_PCT:-15}"
DECAY_PCT="${DECAY_PCT:-3}"
PRUNE_THRESHOLD="${PRUNE_THRESHOLD:-10}"

# ── Helpers ──────────────────────────────────────────────────────────

usage() {
  cat <<'USAGE'
Usage:
  livelearn.sh score              Compute scores for all memory entries
  livelearn.sh reinforce "<pat>"  Boost entries matching pattern
  livelearn.sh decay              Apply time-based decay to all scores
  livelearn.sh consolidate        Merge duplicate memory entries
  livelearn.sh prune              Remove entries scored below threshold
  livelearn.sh recall "<query>"   Search memories and log access
  livelearn.sh status             Show learning metrics
  livelearn.sh cycle              Run full learn cycle (score+decay+consolidate+prune)
USAGE
}

ensure_paths() {
  mkdir -p "${MEM_DIR}"
  touch "${SCORES_FILE}" "${ACCESS_LOG}"
}

epoch_today() {
  date +%s
}

date_today() {
  date +%F
}

# Portable line hash (first 16 chars of sha1).
line_hash() {
  printf '%s' "$1" | sha1sum | cut -c1-16
}

# ── Score storage ────────────────────────────────────────────────────
# Format: hash \t score \t last_accessed_epoch \t created_epoch \t reinforcements \t snippet

get_score_line() {
  local hash="$1"
  awk -F'\t' -v h="${hash}" '$1 == h { print; exit }' "${SCORES_FILE}"
}

set_score_line() {
  local hash="$1" score="$2" accessed="$3" created="$4" reinforcements="$5" snippet="$6"
  local tmp="${SCORES_FILE}.tmp"
  awk -F'\t' -v h="${hash}" '$1 != h' "${SCORES_FILE}" > "${tmp}" || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${hash}" "${score}" "${accessed}" "${created}" "${reinforcements}" "${snippet}" >> "${tmp}"
  mv "${tmp}" "${SCORES_FILE}"
}

# ── Access log ───────────────────────────────────────────────────────
# Format: epoch \t action \t hash \t snippet

log_access() {
  local action="$1" hash="$2" snippet="$3"
  printf '%s\t%s\t%s\t%s\n' "$(epoch_today)" "${action}" "${hash}" "${snippet}" >> "${ACCESS_LOG}"
}

# ── Category weight (integer 80-100) ────────────────────────────────

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

# ── Subcommands ──────────────────────────────────────────────────────

cmd_score() {
  ensure_paths
  local added=0 updated=0
  local now
  now="$(epoch_today)"

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
      local cleaned
      cleaned="$(printf '%s' "${raw_line}" | sed -E 's/^- +//; s/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] +//')"
      if [[ -z "${cleaned}" ]]; then
        continue
      fi

      local hash
      hash="$(line_hash "${cleaned}")"
      local existing
      existing="$(get_score_line "${hash}")"

      if [[ -z "${existing}" ]]; then
        local weight
        weight="$(category_weight "${section}")"
        local weighted_score=$(( INITIAL_SCORE * weight / 100 ))
        set_score_line "${hash}" "${weighted_score}" "${now}" "${now}" "0" "${cleaned:0:120}"
        added=$((added + 1))
      else
        updated=$((updated + 1))
      fi
    done < "${file}"
  done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" | sort)

  echo "score: ok"
  echo "new_entries: ${added}"
  echo "existing_entries: ${updated}"
}

cmd_reinforce() {
  ensure_paths
  local pattern="$1"
  local boosted=0
  local now
  now="$(epoch_today)"

  while IFS=$'\t' read -r hash score accessed created reinforcements snippet; do
    if [[ -z "${hash}" ]]; then
      continue
    fi
    if printf '%s\n' "${snippet}" | rg -Fqi -- "${pattern}"; then
      local boost=$(( (100 - score) * REINFORCE_PCT / 100 ))
      if [[ "${boost}" -lt 1 ]]; then
        boost=1
      fi
      local new_score=$(( score + boost ))
      if [[ "${new_score}" -gt 100 ]]; then
        new_score=100
      fi
      local new_reinforcements=$(( reinforcements + 1 ))
      set_score_line "${hash}" "${new_score}" "${now}" "${created}" "${new_reinforcements}" "${snippet}"
      log_access "reinforce" "${hash}" "${snippet}"
      boosted=$((boosted + 1))
    fi
  done < "${SCORES_FILE}"

  echo "reinforce: ok"
  echo "boosted: ${boosted}"
}

cmd_decay() {
  ensure_paths
  local decayed=0
  local now
  now="$(epoch_today)"

  local tmp="${SCORES_FILE}.tmp"
  : > "${tmp}"

  while IFS=$'\t' read -r hash score accessed created reinforcements snippet; do
    if [[ -z "${hash}" ]]; then
      continue
    fi
    local age_seconds=$(( now - accessed ))
    local age_days=$(( age_seconds / 86400 ))
    if [[ "${age_days}" -lt 1 ]]; then
      age_days=0
    fi

    local new_score="${score}"
    if [[ "${age_days}" -gt 0 ]]; then
      # Apply compounding decay: score * ((100-DECAY_PCT)/100) ^ age_days
      local i=0
      while [[ "${i}" -lt "${age_days}" ]]; do
        new_score=$(( new_score * (100 - DECAY_PCT) / 100 ))
        i=$((i + 1))
      done
      if [[ "${new_score}" -ne "${score}" ]]; then
        decayed=$((decayed + 1))
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${hash}" "${new_score}" "${accessed}" "${created}" "${reinforcements}" "${snippet}" >> "${tmp}"
  done < "${SCORES_FILE}"

  mv "${tmp}" "${SCORES_FILE}"
  echo "decay: ok"
  echo "decayed_entries: ${decayed}"
}

cmd_consolidate() {
  ensure_paths
  local merged=0

  # Find duplicate content across different memory day-files.
  # Two entries are duplicates if they share the same cleaned text hash.
  # Keep only the first occurrence (oldest file) and remove from later files.
  declare -A seen_hashes

  while IFS= read -r file; do
    local tmpfile="${file}.tmp"
    local file_changed=false
    while IFS= read -r raw_line; do
      # Pass through headers and blank lines
      if [[ -z "${raw_line}" || "${raw_line}" == \#* ]]; then
        printf '%s\n' "${raw_line}" >> "${tmpfile}"
        continue
      fi
      local cleaned
      cleaned="$(printf '%s' "${raw_line}" | sed -E 's/^- +//; s/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] +//')"
      if [[ -z "${cleaned}" ]]; then
        printf '%s\n' "${raw_line}" >> "${tmpfile}"
        continue
      fi
      local hash
      hash="$(line_hash "${cleaned}")"
      if [[ -n "${seen_hashes[${hash}]+_}" ]]; then
        # Duplicate found – skip this line
        merged=$((merged + 1))
        file_changed=true
      else
        seen_hashes["${hash}"]=1
        printf '%s\n' "${raw_line}" >> "${tmpfile}"
      fi
    done < "${file}"

    if [[ "${file_changed}" == "true" ]]; then
      mv "${tmpfile}" "${file}"
    else
      rm -f "${tmpfile}"
    fi
  done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" | sort)

  echo "consolidate: ok"
  echo "duplicates_removed: ${merged}"
}

cmd_prune() {
  ensure_paths
  local pruned=0
  local now
  now="$(epoch_today)"

  local tmp="${SCORES_FILE}.tmp"
  : > "${tmp}"
  local pruned_hashes=""

  while IFS=$'\t' read -r hash score accessed created reinforcements snippet; do
    if [[ -z "${hash}" ]]; then
      continue
    fi
    if [[ "${score}" -lt "${PRUNE_THRESHOLD}" ]]; then
      pruned_hashes="${pruned_hashes}${hash}"$'\n'
      log_access "prune" "${hash}" "${snippet}"
      pruned=$((pruned + 1))
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${hash}" "${score}" "${accessed}" "${created}" "${reinforcements}" "${snippet}" >> "${tmp}"
    fi
  done < "${SCORES_FILE}"

  mv "${tmp}" "${SCORES_FILE}"

  # Remove pruned lines from memory files
  if [[ -n "${pruned_hashes}" ]]; then
    while IFS= read -r file; do
      local tmpfile="${file}.tmp"
      local file_changed=false
      while IFS= read -r raw_line; do
        if [[ -z "${raw_line}" || "${raw_line}" == \#* ]]; then
          printf '%s\n' "${raw_line}" >> "${tmpfile}"
          continue
        fi
        local cleaned
        cleaned="$(printf '%s' "${raw_line}" | sed -E 's/^- +//; s/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] +//')"
        if [[ -z "${cleaned}" ]]; then
          printf '%s\n' "${raw_line}" >> "${tmpfile}"
          continue
        fi
        local hash
        hash="$(line_hash "${cleaned}")"
        if printf '%s' "${pruned_hashes}" | rg -Fq "${hash}"; then
          file_changed=true
        else
          printf '%s\n' "${raw_line}" >> "${tmpfile}"
        fi
      done < "${file}"

      if [[ "${file_changed}" == "true" ]]; then
        mv "${tmpfile}" "${file}"
      else
        rm -f "${tmpfile}"
      fi
    done < <(find "${MEM_DIR}" -maxdepth 1 -type f -name "*.md" | sort)
  fi

  echo "prune: ok"
  echo "pruned_entries: ${pruned}"
}

cmd_recall() {
  ensure_paths
  local query="$1"
  local matches=0
  local now
  now="$(epoch_today)"

  while IFS=$'\t' read -r hash score accessed created reinforcements snippet; do
    if [[ -z "${hash}" ]]; then
      continue
    fi
    if printf '%s\n' "${snippet}" | rg -Fqi -- "${query}"; then
      printf '[score:%3d reinf:%d] %s\n' "${score}" "${reinforcements}" "${snippet}"
      # Boost on recall – a lighter touch than explicit reinforce
      local boost=$(( (100 - score) * 5 / 100 ))
      if [[ "${boost}" -lt 1 ]]; then
        boost=1
      fi
      local new_score=$(( score + boost ))
      if [[ "${new_score}" -gt 100 ]]; then
        new_score=100
      fi
      set_score_line "${hash}" "${new_score}" "${now}" "${created}" "${reinforcements}" "${snippet}"
      log_access "recall" "${hash}" "${snippet}"
      matches=$((matches + 1))
    fi
  done < "${SCORES_FILE}"

  echo "---"
  echo "recall: ok"
  echo "matches: ${matches}"
}

cmd_status() {
  ensure_paths
  local total=0 high=0 medium=0 low=0 critical=0
  local max_score=0 min_score=100 sum=0
  local total_reinforcements=0

  while IFS=$'\t' read -r hash score accessed created reinforcements snippet; do
    if [[ -z "${hash}" ]]; then
      continue
    fi
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
  done < "${SCORES_FILE}"

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
  echo "access_log_entries: ${access_count}"
  echo "prune_threshold: ${PRUNE_THRESHOLD}"
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
    prune)       cmd_prune ;;
    recall)      cmd_recall "$*" ;;
    status)      cmd_status ;;
    cycle)       cmd_cycle ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
