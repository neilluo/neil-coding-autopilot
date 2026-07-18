#!/usr/bin/env bash
# telemetry.sh — fail-safe telemetry library for neil-coding-autopilot.
#
# WHAT: sourced (not executed) by dispatch.sh / run-track-a.sh / daily-analysis.sh
#   to append structured JSONL events under $LOG_ROOT/runs/YYYY-MM-DD.jsonl.
#
# FAIL-SAFE CONTRACT (spec.md §5.1 — do not weaken):
#   - every function here returns 0 on every path, EXCEPT telemetry_enabled
#     (a boolean predicate meant for `if telemetry_enabled; then`).
#   - every side-effecting block is wrapped `{ ...; } 2>/dev/null || true` so a
#     caller running under `set -euo pipefail` never aborts because of us.
#   - NEVER write to stdout: stdout is the worker's output, parsed by
#     parse-status.sh / parse_review for DONE/REVIEW_PASS — polluting it would
#     break real control flow, not just telemetry.
#   - all variable references use ${VAR:-} so `set -u` callers survive sourcing.
#
# PORTABILITY: bash 3.2 (macOS stock) — no associative arrays, no mapfile.

# ── telemetry_enabled: env switch (NEIL_AUTOPILOT_TELEMETRY=0 disables) ─────
telemetry_enabled() {
  [ "${NEIL_AUTOPILOT_TELEMETRY:-1}" != "0" ]
}

# ── internal: sanitize a value to a non-negative-or-negative integer, or 0 ──
_telemetry_int() {
  local v="${1:-0}"
  case "$v" in
    ''|*[!0-9-]*) echo 0 ;;
    *) echo "$v" ;;
  esac
  return 0
}

# ── telemetry_log_root: resolve $LOG_ROOT, apply CWD safety guard, grow dirs ─
# Echoes the resolved root, or empty string if unusable. Always returns 0.
telemetry_log_root() {
  local root="" cwd=""
  root="${NEIL_AUTOPILOT_LOG_DIR:-${HOME:-}/neil-autopilot-logs-analysis}"
  if [ -z "$root" ]; then
    echo ""
    return 0
  fi

  # Safety guard (C12): never let telemetry land inside the business project's
  # CWD, or `git add -A` in run-track-a.sh would sweep logs into a real commit.
  cwd="$(pwd -P 2>/dev/null || pwd)"
  case "$root" in
    "$cwd"|"$cwd"/*)
      root="${TMPDIR:-/tmp}/neil-autopilot-logs-analysis"
      ;;
  esac

  if ! mkdir -p "$root/runs" "$root/metrics" "$root/reports" 2>/dev/null; then
    echo ""
    return 0
  fi
  if [ ! -w "$root" ]; then
    echo ""
    return 0
  fi

  echo "$root"
  return 0
}

# ── telemetry_json_escape: pure-bash param-expansion escaping (bash 3.2) ────
# Backslash MUST be escaped first, else the later substitutions double-escape.
telemetry_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
  return 0
}

# ── telemetry_emit <json>: append one line to today's runs/*.jsonl ──────────
telemetry_emit() {
  local json="${1:-}"
  {
    if telemetry_enabled && [ -n "$json" ]; then
      local root=""
      root="$(telemetry_log_root)"
      if [ -n "$root" ]; then
        printf '%s\n' "$json" >> "$root/runs/$(date +%F).jsonl"
      fi
    fi
  } 2>/dev/null || true
  return 0
}

# ── telemetry_rotate [days]: delete runs/ older than `days` (default 3) ─────
# `-delete` cannot remove non-empty directories, hence the separate -exec rm -rf.
telemetry_rotate() {
  local days="${1:-${NEIL_AUTOPILOT_KEEP_DAYS:-3}}"
  case "$days" in
    ''|*[!0-9]*) days=3 ;;
  esac
  local root=""
  root="$(telemetry_log_root)"
  [ -n "$root" ] || return 0
  [ -d "$root/runs" ] || return 0
  {
    find "$root/runs" -maxdepth 1 -name '*.jsonl' -mtime "+$((days - 1))" -delete
    find "$root/runs" -mindepth 1 -maxdepth 1 -type d -mtime "+$((days - 1))" -exec rm -rf {} +
  } 2>/dev/null || true
  return 0
}

# ── event constructors (spec.md §3.2) ───────────────────────────────────────
# Each builds one JSON line and emits it via telemetry_emit. `ts` is always
# UTC, command-pinned `date -u +%Y-%m-%dT%H:%M:%SZ`.

# telemetry_emit_dispatch <exit_code> <start_epoch_s>
# Reads stage/run_id/model from the caller's environment (dispatch.sh sources
# this file into its own shell, so AUTOPILOT_STAGE/AUTOPILOT_RUN_ID/MODEL are
# visible here without being passed explicitly).
telemetry_emit_dispatch() {
  local exit_code="${1:-0}" start_ts="${2:-}"
  {
    local now="" dur=0 stage="" run_id="" model="" json=""
    now="$(date +%s)"
    if [ -n "$start_ts" ]; then
      dur=$((now - start_ts))
    fi
    stage="${AUTOPILOT_STAGE:-unknown}"
    run_id="${AUTOPILOT_RUN_ID:-$(date +%F)-$$}"
    model="${MODEL:-}"
    exit_code="$(_telemetry_int "$exit_code")"
    dur="$(_telemetry_int "$dur")"
    json=$(printf '{"ts":"%s","run_id":"%s","event":"dispatch","stage":"%s","model":"%s","duration_s":%s,"exit_code":%s}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(telemetry_json_escape "$run_id")" \
      "$(telemetry_json_escape "$stage")" \
      "$(telemetry_json_escape "$model")" \
      "$dur" "$exit_code")
    telemetry_emit "$json"
  } 2>/dev/null || true
  return 0
}

# telemetry_emit_round <run_id> <task> <round> <verify:pass|fail|skip> <review:REVIEW_PASS|REVIEW_FAIL|REVIEW_INCOMPLETE|UNKNOWN>
telemetry_emit_round() {
  local run_id="${1:-}" task="${2:-}" round="${3:-0}" verify="${4:-skip}" review="${5:-UNKNOWN}"
  {
    local json=""
    round="$(_telemetry_int "$round")"
    json=$(printf '{"ts":"%s","run_id":"%s","event":"round","task":"%s","round":%s,"verify":"%s","review":"%s"}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(telemetry_json_escape "$run_id")" \
      "$(telemetry_json_escape "$task")" \
      "$round" \
      "$(telemetry_json_escape "$verify")" \
      "$(telemetry_json_escape "$review")")
    telemetry_emit "$json"
  } 2>/dev/null || true
  return 0
}

# telemetry_emit_task <run_id> <task> <title> <final_status:DONE|BLOCKED> <rounds> <committed:true|false>
telemetry_emit_task() {
  local run_id="${1:-}" task="${2:-}" title="${3:-}" final_status="${4:-BLOCKED}" rounds="${5:-0}" committed="${6:-false}"
  {
    local json=""
    rounds="$(_telemetry_int "$rounds")"
    title="${title:0:200}"
    case "$committed" in
      true|false) : ;;
      *) committed=false ;;
    esac
    json=$(printf '{"ts":"%s","run_id":"%s","event":"task","task":"%s","title":"%s","final_status":"%s","rounds":%s,"committed":%s}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(telemetry_json_escape "$run_id")" \
      "$(telemetry_json_escape "$task")" \
      "$(telemetry_json_escape "$title")" \
      "$(telemetry_json_escape "$final_status")" \
      "$rounds" "$committed")
    telemetry_emit "$json"
  } 2>/dev/null || true
  return 0
}

# telemetry_emit_run <run_id> <change> <outcome:complete|blocked|interrupted> <duration_s>
telemetry_emit_run() {
  local run_id="${1:-}" change="${2:-}" outcome="${3:-interrupted}" duration_s="${4:-0}"
  {
    local json=""
    duration_s="$(_telemetry_int "$duration_s")"
    json=$(printf '{"ts":"%s","run_id":"%s","event":"run","change":"%s","outcome":"%s","duration_s":%s}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(telemetry_json_escape "$run_id")" \
      "$(telemetry_json_escape "$change")" \
      "$(telemetry_json_escape "$outcome")" \
      "$duration_s")
    telemetry_emit "$json"
  } 2>/dev/null || true
  return 0
}
