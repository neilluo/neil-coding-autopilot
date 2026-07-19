#!/usr/bin/env bash
# ============================================================================
# e2e-suite.sh — Controller Write Hard-Gate, REAL qodercli end-to-end suite (v2)
# ----------------------------------------------------------------------------
# Extends the original 4-case e2e-test.sh to 16 cases covering EVERY guard layer
# in hooks/guard-controller-write.sh:
#   L1  scope gate   (no sentinel      => allow)      cases 14,15
#   L1b stale gate   (sentinel >12h    => allow)      case  16
#   L2  worker allow (AUTOPILOT_ROLE   => allow)      cases 7,8,9
#   L3  whitelist    (md/autopilot/AGENTS => allow)   cases 10,11,12,13
#   L4  DENY         (controller src   => deny)       cases 1-6
#
# Each case launches a REAL `qodercli -p` session (headless, bypass mode) with
# the guard injected via --settings, inside a throwaway project that varies
# (sentinel present? stale? AUTOPILOT_ROLE=worker?). We then assert on the
# filesystem outcome:
#     created   => target file exists afterwards      (allow expected)
#     blocked   => target file does NOT exist          (deny  expected)
#     unchanged => existing target's content untouched  (deny of Edit expected)
#
# ROBUSTNESS:
#  * every session runs with `--disallowed-tools Bash` so the model CANNOT
#    shell-redirect around the Write/Edit tools the guard gates (bash
#    redirection is out-of-scope for this MVP; disallowing it removes the only
#    confounder and keeps each case measuring the guard's real path).
#  * deny cases require BOTH the safety property (file not created / unchanged)
#    AND positive proof the guard fired (its reason surfaced in the session
#    log) — so an unrelated setup/filesystem error can never false-pass.
#  * any case that misses its expectation is retried once to absorb transient
#    model/network flakiness before being recorded as a FAIL.
#
# PORTABILITY: bash 3.2 (stock macOS). NB: bash 3.2 evaluates ALL rhs on a
# single `local a=.. b=$a` line BEFORE binding any, so same-line local back-
# references are unbound under `set -u`; such locals are kept as separate stmts.
#
# Usage:   bash e2e-suite.sh            (E2E_MODEL overrides the model)
# Exit:    0 = all cases pass, 1 = any failure.
# ============================================================================
set -uo pipefail

PLUGIN="/Users/neil/Desktop/neilcodebase/neil-coding-autopilot"
GUARD="$PLUGIN/hooks/guard-controller-write.sh"
MODEL="${E2E_MODEL:-Performance}"
ORIG_EDIT="class Legacy {}"   # pre-existing content for the Edit-deny case

[ -f "$GUARD" ] || { echo "FATAL: guard not found: $GUARD" >&2; exit 1; }
command -v qodercli >/dev/null 2>&1 || { echo "FATAL: qodercli not on PATH" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-e2e-guard.XXXXXX")"
RESULTS="$SANDBOX/results.log"
SETTINGS="$SANDBOX/guard-settings.json"
cat > "$SETTINGS" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Write|Edit|MultiEdit|write|edit|create_file|write_file|search_replace|replace|NotebookEdit","hooks":[{"type":"command","command":"$GUARD"}]}]}}
JSON

echo "== E2E suite (controller write hard-gate) =="       | tee "$RESULTS"
echo "== sandbox: $SANDBOX =="                            | tee -a "$RESULTS"
echo "== model:   $MODEL =="                              | tee -a "$RESULTS"
echo "== guard:   $GUARD =="                              | tee -a "$RESULTS"
echo ""                                                   | tee -a "$RESULTS"

pass=0; fail=0; total=0

# mkproj <name> <sentinel: none|fresh|stale>  -> prints project dir
mkproj() {
  local name="$1"; local sent="$2"; local p="$SANDBOX/$name"   # split: bash-3.2 safe
  mkdir -p "$p"
  if [ "$sent" != "none" ]; then
    mkdir -p "$p/autopilot"
    { date +%s; echo "pid=e2e"; echo "started=$(date '+%Y-%m-%d %H:%M:%S')"; } > "$p/autopilot/.run-active"
    if [ "$sent" = "stale" ]; then
      # age the sentinel past the 12h TTL so layer-1b treats it as crash residue
      if date -v-13H +%Y%m%d%H%M >/dev/null 2>&1; then
        touch -t "$(date -v-13H +%Y%m%d%H%M)" "$p/autopilot/.run-active"        # BSD/macOS
      else
        touch -d '13 hours ago' "$p/autopilot/.run-active" 2>/dev/null || true  # GNU
      fi
    fi
  fi
  printf '%s' "$p"
}

# run_case <label> <projdir> <role|""> <tool: write|edit> <target-rel> <expect: created|blocked|unchanged>
run_case() {
  local label="$1"; local proj="$2"; local role="$3"; local tool="$4"; local target="$5"; local expect="$6"
  local instr log created deny ok attempt content
  total=$((total + 1))

  # Defense-in-depth: a broken setup (empty proj) must NEVER write to '/' and it
  # must NEVER be able to false-pass a `blocked` case. Fail loudly instead.
  if [ -z "$proj" ] || [ ! -d "$proj" ]; then
    fail=$((fail + 1))
    printf '[FAIL] %s\n      setup error: project dir missing/empty (proj=%s)\n' "$label" "$proj" | tee -a "$RESULTS"
    return
  fi
  log="$proj/session.log"

  if [ "$tool" = "edit" ]; then
    instr="Use ONLY your file-editing tool (Edit) to modify the EXISTING file ${target}: append a new line containing exactly // touched. Do NOT use the shell, Bash, or terminal. Do NOT ask for confirmation. Make the edit, then stop."
  else
    instr="Use ONLY your file-writing tool (Write) to create a file at path ${target} with a single line of placeholder content. Do NOT use the shell, Bash, or terminal. Do NOT ask for confirmation. Create it, then stop."
  fi

  ok="FAIL"
  attempt=1
  while [ "$attempt" -le 2 ]; do
    # (re)prime per-attempt state
    if [ "$tool" = "edit" ]; then
      mkdir -p "$proj/$(dirname "$target")"
      printf '%s' "$ORIG_EDIT" > "$proj/$target"   # reset the file the agent will try to edit
    else
      rm -f "$proj/$target" 2>/dev/null || true
    fi
    : > "$log"

    if [ -n "$role" ]; then
      AUTOPILOT_ROLE="$role" qodercli -m "$MODEL" -w "$proj" \
        --permission-mode bypass_permissions --disallowed-tools Bash \
        --settings "$SETTINGS" -o text -p "$instr" < /dev/null > "$log" 2>&1
    else
      env -u AUTOPILOT_ROLE qodercli -m "$MODEL" -w "$proj" \
        --permission-mode bypass_permissions --disallowed-tools Bash \
        --settings "$SETTINGS" -o text -p "$instr" < /dev/null > "$log" 2>&1
    fi

    created="no"; [ -f "$proj/$target" ] && created="yes"
    deny="no"; grep -qiE 'run-track-a|禁止内联写源码|blocking this write|hook is blocking|managed workflow' "$log" 2>/dev/null && deny="yes"

    case "$expect" in
      created)   [ "$created" = "yes" ] && ok="PASS" ;;
      blocked)   [ "$created" = "no"  ] && [ "$deny" = "yes" ] && ok="PASS" ;;
      unchanged) content="$(cat "$proj/$target" 2>/dev/null || printf '')"
                 [ "$content" = "$ORIG_EDIT" ] && [ "$deny" = "yes" ] && ok="PASS" ;;
    esac
    [ "$ok" = "PASS" ] && break
    attempt=$((attempt + 1))
  done

  if [ "$ok" = "PASS" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
  {
    printf '[%s] %s\n' "$ok" "$label"
    printf '      expect=%-9s created=%-3s guard_denied_in_log=%-3s tries=%s  (%s)\n' \
      "$expect" "$created" "$deny" "$attempt" "$target"
  } | tee -a "$RESULTS"
}

# ── LAYER 4: DENY — controller writes source during an active run ────────────
run_case "01 controller Write .java (run active)"      "$(mkproj c01 fresh)" ""       write "src/App.java"                blocked
run_case "02 controller Write .py (run active)"        "$(mkproj c02 fresh)" ""       write "src/main.py"                 blocked
run_case "03 controller Write .sh (run active)"        "$(mkproj c03 fresh)" ""       write "scripts/build.sh"            blocked
run_case "04 controller Write .ts (run active)"        "$(mkproj c04 fresh)" ""       write "app/index.ts"                blocked
run_case "05 controller Write nested .java (run)"      "$(mkproj c05 fresh)" ""       write "a/b/c/Deep.java"             blocked
run_case "06 controller Edit existing .java (run)"     "$(mkproj c06 fresh)" ""       edit  "src/Legacy.java"             unchanged

# ── LAYER 2: worker allow (AUTOPILOT_ROLE=worker) ────────────────────────────
run_case "07 worker Write .java (run active)"          "$(mkproj c07 fresh)" worker   write "src/App.java"                created
run_case "08 worker Write .py (run active)"            "$(mkproj c08 fresh)" worker   write "src/util.py"                 created
run_case "09 worker Write nested .go (run active)"     "$(mkproj c09 fresh)" worker   write "pkg/mod/deep.go"             created

# ── LAYER 3: whitelist allow (md / autopilot / harness) ──────────────────────
run_case "10 controller Write .md (run active)"        "$(mkproj c10 fresh)" ""       write "notes.md"                    created
run_case "11 controller Write nested .md (run active)" "$(mkproj c11 fresh)" ""       write "docs/guide.md"               created
run_case "12 controller Write autopilot/ (run active)" "$(mkproj c12 fresh)" ""       write "autopilot/changes/x/spec.md" created
run_case "13 controller Write AGENTS.md (run active)"  "$(mkproj c13 fresh)" ""       write "AGENTS.md"                   created

# ── LAYER 1: scope gate (no sentinel => normal coding, never gated) ──────────
run_case "14 normal coding .java (no sentinel)"        "$(mkproj c14 none)"  ""       write "src/App.java"                created
run_case "15 normal coding .py (no sentinel)"          "$(mkproj c15 none)"  ""       write "config/app.py"               created

# ── LAYER 1b: stale gate (sentinel older than 12h TTL => allow) ──────────────
run_case "16 stale sentinel .java (>12h old)"          "$(mkproj c16 stale)" ""       write "src/App.java"                created

echo ""                                                                | tee -a "$RESULTS"
echo "== E2E SUMMARY: ${pass} passed, ${fail} failed (of ${total}) =="  | tee -a "$RESULTS"
echo "== sandbox kept for inspection: $SANDBOX =="                      | tee -a "$RESULTS"
if [ "$fail" -eq 0 ]; then
  echo "E2E: ALL PASS" | tee -a "$RESULTS"; exit 0
else
  echo "E2E: FAILED"   | tee -a "$RESULTS"; exit 1
fi
