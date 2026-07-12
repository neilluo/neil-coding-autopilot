#!/usr/bin/env bash
# ============================================================
# neil-coding-autopilot — Controller Bash-Write Hard-Gate (PreToolUse: Bash)
# ============================================================
# Closes shell bypasses of guard-controller-write.sh (which only covers file
# TOOLS). A controller could otherwise write source during a run via the shell.
# Vectors gated (conservative, fail-open):
#   (a) redirection: `cat > x.py`, `echo >> x.go`, `>| x.rs`, `&> x.py`,
#                    `… | tee x.java`, `dd of=x.rs`
#   (b) in-place edit: `sed -i … x.py`, `perl -pi -e … x.go`, `ruby -i … x.rb`
#   (c) interpreter write: `python -c "open('x.py','w')…"`,
#                    node `writeFileSync('x.js', …)`
#
# Decision order — FAIL-OPEN on any uncertainty (never block legit shell):
#   0. trap             any internal error                    => allow (exit 0)
#   1. scope gate       no autopilot/.run-active               => allow (not a run)
#   1b. stale sentinel  sentinel older than TTL                 => allow (crash residue)
#   2. worker allow     AUTOPILOT_ROLE=worker                   => allow
#   3. gather targets   no source-write vector detected         => allow
#   4. otherwise        controller shell-writing source at run  => DENY (exit 2)
#
# Only a target with a known SOURCE-code extension that is NOT whitelisted
# (*.md / autopilot/ / .qoder/ / /dev/*) triggers a deny. read-only opens,
# extensionless/.txt/.log targets, and all git/verify/dispatch shell fail-open.
# ============================================================

set +e +u
trap 'exit 0' ERR

_STDIN="$(cat 2>/dev/null || true)"

_field() {
  local q="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$_STDIN" | jq -r "$q // empty" 2>/dev/null
  else
    printf '%s' "$_STDIN" \
      | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

TOOL_NAME="$(_field '.tool_name' 'tool_name')"
CWD="$(_field '.cwd' 'cwd')"
CMD="$(_field '.tool_input.command' 'command')"

case "$TOOL_NAME" in
  Bash|bash|shell|Shell|run_terminal_cmd|terminal|Terminal|execute_command) ;;
  *) exit 0 ;;
esac

# --- layer 1: scope gate — only active INSIDE an autopilot run ---
BASE="${CWD:-$PWD}"
SENTINEL="${BASE%/}/autopilot/.run-active"
[ -f "$SENTINEL" ] || exit 0

# --- layer 1b: ignore a STALE sentinel (crash residue) ---
TTL_H="${AUTOPILOT_RUN_TTL_HOURS:-12}"
if [[ "${OSTYPE:-}" == darwin* ]]; then
  _born=$(stat -f '%m' "$SENTINEL" 2>/dev/null || echo 0)
else
  _born=$(stat -c '%Y' "$SENTINEL" 2>/dev/null || echo 0)
fi
_now=$(date +%s 2>/dev/null || echo 0)
if [ "${_born:-0}" -gt 0 ] 2>/dev/null && [ "${_now:-0}" -gt 0 ] 2>/dev/null; then
  [ $(( _now - _born )) -gt $(( TTL_H * 3600 )) ] 2>/dev/null && exit 0
fi

# --- layer 2: worker allow — dispatched workers write freely ---
[ "${AUTOPILOT_ROLE:-}" = "worker" ] && exit 0

# --- layer 3: gather candidate WRITE targets (multi-vector, conservative) ---
[ -z "$CMD" ] && exit 0
_EXT='py|pyi|java|js|jsx|ts|tsx|go|rs|c|cc|cpp|h|hpp|rb|php|cs|kt|kts|scala|swift|m|mm|sh|bash|sql|vue|svelte'
_targets=""

# (a) redirection / tee / dd targets (>, >>, >|, &>, tee [-a], dd of=)
_targets="$_targets
$(printf '%s' "$CMD" | grep -oE '(>>?\|?[[:space:]]*|&>[[:space:]]*|[[:space:]]tee[[:space:]]+(-a[[:space:]]+)?|[[:space:]]dd[[:space:]]+[^|;&]*of=)["'"'"']?[^ "'"'"'|;&<>()]+' 2>/dev/null \
  | sed -E 's/^[[:space:]]*(>>?\|?|&>|tee([[:space:]]+-a)?|dd[[:space:]].*of=)[[:space:]]*//; s/^["'"'"']//')"

# (b) in-place stream editors (sed -i / perl -[p]i / ruby -i) — flag source-ext file tokens
if printf '%s' "$CMD" | grep -qE '(sed|perl|ruby)[[:space:]]([^;&|]*[[:space:]])?-[A-Za-z]*i([.][^[:space:]]*)?([[:space:]]|$)' 2>/dev/null; then
  _targets="$_targets
$(printf '%s' "$CMD" | grep -oE "[[:alnum:]_./-]+\.($_EXT)([[:space:]]|\$)" 2>/dev/null | sed -E 's/[[:space:]]+$//')"
fi

# (c) interpreter inline writes: open(<src>,'w'|'a'|'x') / writeFileSync(<src>)
if printf '%s' "$CMD" | grep -qE '(python3?|node|ruby|perl)[^|;&]*[[:space:]]-(c|e)([[:space:]]|$)' 2>/dev/null; then
  _targets="$_targets
$(printf '%s' "$CMD" | grep -oE "open\([[:space:]]*[\"'][^\"']+\.($_EXT)[\"'][[:space:]]*,[[:space:]]*[\"'][wax]" 2>/dev/null | grep -oE "[\"'][^\"']+\.($_EXT)[\"']" | tr -d "\"'")
$(printf '%s' "$CMD" | grep -oE "(writeFileSync|writeFile|appendFileSync)\([[:space:]]*[\"'][^\"']+\.($_EXT)[\"']" 2>/dev/null | grep -oE "[\"'][^\"']+[\"']" | tr -d "\"'")"
fi

_targets="$(printf '%s\n' "$_targets" | grep -v '^[[:space:]]*$' 2>/dev/null || true)"
[ -z "$_targets" ] && exit 0

# --- layer 4: deny if any candidate is a SOURCE file not on the whitelist ---
_deny_path=""
_IFS_SAVE="$IFS"; IFS='
'
for _t in $_targets; do
  [ -z "$_t" ] && continue
  case "$_t" in
    *.md|*.MD|*.markdown)              continue ;;  # docs / prompt templates
    */autopilot/*|autopilot/*)         continue ;;  # spec / tasks / knowledge
    */.qoder/*|*/AGENTS.md|AGENTS.md)  continue ;;  # harness artifacts
    /dev/*)                            continue ;;  # /dev/null, /dev/stderr …
  esac
  case "$_t" in
    *.py|*.pyi|*.java|*.js|*.jsx|*.ts|*.tsx|*.go|*.rs|*.c|*.cc|*.cpp|*.h|*.hpp|*.rb|*.php|*.cs|*.kt|*.kts|*.scala|*.swift|*.m|*.mm|*.sh|*.bash|*.sql|*.vue|*.svelte)
      _deny_path="$_t"; break ;;
  esac
done
IFS="$_IFS_SAVE"

[ -z "$_deny_path" ] && exit 0   # no source-file write detected => allow

REASON="控制器禁止用 shell 写源码(${_deny_path})；autopilot 开发一律经 run-track-a.sh 托管 fresh qodercli worker（结构性硬约束，非仅约定）。"
_esc="${_deny_path//\\/\\\\}"; _esc="${_esc//\"/\\\"}"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"控制器禁止用 shell 写源码(%s)；开发一律经 run-track-a.sh 托管 worker。"}}\n' "$_esc"
printf '%s\n' "$REASON" >&2
exit 2
