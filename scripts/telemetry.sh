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
#
# SINK SEAM (spec.md §3.3 — cloud-migration insurance, extension point only):
#   telemetry_emit routes through _telemetry_sink_dispatch, which picks a
#   backend function by name: `${NEIL_AUTOPILOT_LOG_SINK:-file}` -> function
#   `_telemetry_sink_<name>`. To add a backend (e.g. oss/sls), just define
#   `_telemetry_sink_<name>() { ... }` below (same fail-safe contract as
#   `_telemetry_sink_file`) and set NEIL_AUTOPILOT_LOG_SINK=<name> — the
#   dispatcher discovers it by name, no dispatcher changes needed. Unknown
#   sink names fall back to `file` (fail-safe: never silently drop events).
#   No `stdout` sink is added here: stdout is the worker's output channel
#   (see FAIL-SAFE CONTRACT above) and a stdout sink would break that
#   contract; cloud stdout collection is a future, separately designed sink.

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

_telemetry_num() {
  local v="${1:-}"
  if printf '%s\n' "$v" | LC_ALL=C grep -Eq '^-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][+-]?[0-9]+)?$'; then
    printf '%s' "$v"
  fi
  return 0
}

# ── internal: 把一个可能尚不存在的绝对路径归一到物理路径 ────────────────
# 向上找到第一个**存在的**祖先目录做 `cd && pwd -P`，再拼回剩余组件。
# 只回退一级父目录是不够的：当 root 与其直接父目录都不存在时（如
# NEIL_AUTOPILOT_LOG_DIR=/tmp/<repo>/logs/tm 而 logs/ 还没建），root_phys 会保持字面量
# 不归一，于是 macOS 上 /tmp → /private/tmp 的符链别名又能绕过 C12 守卫，
# 把遥测目录建进业务仓库并被 `git add -A` 提交。bash 3.2 安全写法。
_telemetry_phys_path() {
  local p="${1:-}" suffix=""
  case "$p" in
    /*) ;;
    *) printf '%s' "$p"; return 0 ;;
  esac
  while [ ! -d "$p" ] && [ "$p" != "/" ] && [ -n "$p" ]; do
    suffix="/$(basename "$p")$suffix"
    p="$(dirname "$p")"
  done
  if [ -d "$p" ]; then
    printf '%s%s' "$(cd "$p" 2>/dev/null && pwd -P || printf '%s' "$p")" "$suffix"
  else
    printf '%s%s' "$p" "$suffix"
  fi
  return 0
}

# ── telemetry_log_root: resolve $LOG_ROOT, apply CWD safety guard, grow dirs ─
# Echoes the resolved root, or empty string if unusable. Always returns 0.
# 注：本文件是被 source 的，所有临时变量必须 local，否则会污染调用方的 shell。
telemetry_log_root() {
  local root="" cwd_phys="" cwd_logical="" root_phys="" fallback="" parent="" c=""
  root="${NEIL_AUTOPILOT_LOG_DIR:-${HOME:-}/Library/Logs/neil-autopilot}"
  if [ -z "$root" ]; then
    echo ""
    return 0
  fi
  fallback="${TMPDIR:-/tmp}/neil-autopilot-logs-analysis"

  # Safety guard (C12): never let telemetry land inside the business project's
  # CWD, or `git add -A` in run-track-a.sh would sweep logs into a real commit.
  #
  # 旧实现直接拿**未规范化的 $root 字面量**去比 `pwd -P` 的物理路径，两类真实输入
  # 都能绕过它（均已实测复现，直接在业务 CWD 里建出了目录）：
  #   ① 相对路径：NEIL_AUTOPILOT_LOG_DIR=logs 不以 $cwd 开头，case 不命中，而它本质就是
  #     相对 CWD 解析的 —— 相对路径一律当作“落在业务目录内”处理。
  #   ② 符链别名：macOS 的 /tmp 是 /private/tmp 的符链，业务仓在 /tmp/proj 时
  #     `pwd -P` 得 /private/tmp/proj，而用户设 /tmp/proj/logs 字面量就对不上。
  # 因此：先强制绝对路径，再把两侧都归一到物理路径后比较（目录可能尚不存在，
  # 退而解析其父目录），并同时对照物理 cwd 与逻辑 cwd。
  case "$root" in
    /*) ;;
    *) root="$fallback" ;;
  esac
  cwd_phys="$(pwd -P 2>/dev/null || pwd)"
  cwd_logical="${PWD:-$cwd_phys}"
  root_phys="$(_telemetry_phys_path "$root")"
  for c in "$cwd_phys" "$cwd_logical"; do
    [ -n "$c" ] || continue
    case "$root_phys" in "$c"|"$c"/*) root="$fallback"; break ;; esac
    case "$root" in "$c"|"$c"/*) root="$fallback"; break ;; esac
  done

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

# ── telemetry_emit <json>: route one JSON line to the active sink ──────────
telemetry_emit() {
  local json="${1:-}"
  {
    if telemetry_enabled && [ -n "$json" ]; then
      _telemetry_sink_dispatch "$json"
    fi
  } 2>/dev/null || true
  return 0
}

# ── internal: true if $1 names a currently-defined shell function ──────────
_telemetry_is_function() {
  [ "$(type -t "${1:-}" 2>/dev/null)" = "function" ]
}

# ── internal: pick backend by ${NEIL_AUTOPILOT_LOG_SINK:-file}, never eval ──
# Unknown/undefined sink names fall back to _telemetry_sink_file (fail-safe:
# a typo in the env var must never silently drop events).
_telemetry_sink_dispatch() {
  local json="${1:-}" sink="${NEIL_AUTOPILOT_LOG_SINK:-file}" fn=""
  fn="_telemetry_sink_${sink}"
  if _telemetry_is_function "$fn"; then
    "$fn" "$json"
  else
    _telemetry_sink_file "$json"
  fi
  return 0
}

# ── default backend: append one line to today's runs/*.jsonl ───────────────
_telemetry_sink_file() {
  local json="${1:-}" root=""
  root="$(telemetry_log_root)"
  if [ -n "$root" ]; then
    printf '%s\n' "$json" >> "$root/runs/$(date +%F).jsonl"
  fi
  return 0
}

# ── telemetry_rotate [days]: delete runs/ older than `days` (default 30) ────
# `-delete` cannot remove non-empty directories, hence the separate -exec rm -rf.
telemetry_rotate() {
  local days="${1:-${NEIL_AUTOPILOT_KEEP_DAYS:-30}}"
  case "$days" in
    ''|*[!0-9]*) days=30 ;;
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
    local now="" dur=0 stage="" run_id="" model="" json="" value=""
    now="$(date +%s)"
    if [ -n "$start_ts" ]; then
      dur=$((now - start_ts))
    fi
    stage="${AUTOPILOT_STAGE:-unknown}"
    run_id="${AUTOPILOT_RUN_ID:-$(date +%F)-$$}"
    model="${MODEL:-}"
    exit_code="$(_telemetry_int "$exit_code")"
    dur="$(_telemetry_int "$dur")"
    json=$(printf '{"ts":"%s","run_id":"%s","event":"dispatch","stage":"%s","model":"%s","duration_s":%s,"exit_code":%s' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(telemetry_json_escape "$run_id")" \
      "$(telemetry_json_escape "$stage")" \
      "$(telemetry_json_escape "$model")" \
      "$dur" "$exit_code")
    # channel 区分「谁在干活」：cli = headless worker 进程（单独计费、fresh context），
    # subagent = 主控会话内的 subagent（计费归主控会话、共享上下文）。
    # 没有这个字段时，两条路径的成本/耗时根本无法对比 —— 2026-08-16 那个
    # 9h37min / 13128 credits 的整夜就是因为 subagent 路径完全不写遥测而彻底不可归因。
    if [ -n "${AUTOPILOT_TM_CHANNEL:-}" ]; then
      json="$json,\"channel\":\"$(telemetry_json_escape "$AUTOPILOT_TM_CHANNEL")\""
    fi
    if [ -n "${AUTOPILOT_TM_TASK:-}" ]; then
      json="$json,\"task\":\"$(telemetry_json_escape "$AUTOPILOT_TM_TASK")\""
    fi
    if [ -n "${AUTOPILOT_TM_INPUT_TOKENS:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_INPUT_TOKENS")"
      json="$json,\"input_tokens\":$value"
    fi
    if [ -n "${AUTOPILOT_TM_OUTPUT_TOKENS:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_OUTPUT_TOKENS")"
      json="$json,\"output_tokens\":$value"
    fi
    if [ -n "${AUTOPILOT_TM_CACHE_READ_TOKENS:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_CACHE_READ_TOKENS")"
      json="$json,\"cache_read_tokens\":$value"
    fi
    value="$(_telemetry_num "${AUTOPILOT_TM_COST_USD:-}")"
    [ -z "$value" ] || json="$json,\"cost_usd\":$value"
    value="$(_telemetry_num "${AUTOPILOT_TM_CONTEXT_RATIO:-}")"
    [ -z "$value" ] || json="$json,\"context_ratio\":$value"
    if [ -n "${AUTOPILOT_TM_NUM_TURNS:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_NUM_TURNS")"
      json="$json,\"num_turns\":$value"
    fi
    if [ -n "${AUTOPILOT_TM_API_MS:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_API_MS")"
      json="$json,\"api_ms\":$value"
    fi
    if [ -n "${AUTOPILOT_TM_ATTEMPT:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_ATTEMPT")"
      json="$json,\"attempt\":$value"
    fi
    if [ -n "${AUTOPILOT_TM_FAILURE_CLASS:-}" ]; then
      json="$json,\"failure_class\":\"$(telemetry_json_escape "$AUTOPILOT_TM_FAILURE_CLASS")\""
    fi
    if [ -n "${AUTOPILOT_TM_PROMPT_BYTES:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_PROMPT_BYTES")"
      json="$json,\"prompt_bytes\":$value"
    fi
    if [ -n "${AUTOPILOT_TM_OUTPUT_BYTES:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_OUTPUT_BYTES")"
      json="$json,\"output_bytes\":$value"
    fi
    # stderr 字节数必须与 stdout 分开记：两股流合并后，「CLI 一个字没说」与
    # 「我们把 stderr 丢了」在日志里长得一模一样（已在 2026-08-16 的排查里卡住一次）。
    if [ -n "${AUTOPILOT_TM_STDERR_BYTES:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_STDERR_BYTES")"
      json="$json,\"stderr_bytes\":$value"
    fi
    # session_id 是事后取证的钥匙：凭它能直接定位 CLI 落盘的完整回合 transcript。
    if [ -n "${AUTOPILOT_TM_SESSION_ID:-}" ]; then
      json="$json,\"session_id\":\"$(telemetry_json_escape "$AUTOPILOT_TM_SESSION_ID")\""
    fi
    # 取证结论（REPORTED / WORK_DONE_UNREPORTED / TRUNCATED_TOOL_USE / THINKING_ONLY）。
    # 这是区分「重试安全」与「重试会叠在半成品上」的唯一字段，必须进自进化数据。
    if [ -n "${AUTOPILOT_TM_FORENSIC_VERDICT:-}" ]; then
      json="$json,\"forensic_verdict\":\"$(telemetry_json_escape "$AUTOPILOT_TM_FORENSIC_VERDICT")\""
    fi
    if [ -n "${AUTOPILOT_TM_STOP_REASON:-}" ]; then
      json="$json,\"stop_reason\":\"$(telemetry_json_escape "$AUTOPILOT_TM_STOP_REASON")\""
    fi
    if [ -n "${AUTOPILOT_TM_TOOL_CALLS:-}" ]; then
      value="$(_telemetry_int "$AUTOPILOT_TM_TOOL_CALLS")"
      json="$json,\"tool_calls\":$value"
    fi
    case "${AUTOPILOT_TM_IS_ERROR:-}" in
      true|false) json="$json,\"is_error\":${AUTOPILOT_TM_IS_ERROR}" ;;
    esac
    telemetry_emit "$json}"
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
