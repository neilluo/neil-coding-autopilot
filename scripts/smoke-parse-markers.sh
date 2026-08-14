#!/usr/bin/env bash
set -euo pipefail
unset AUTOPILOT_RUN_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PARSE="$SCRIPT_DIR/parse-markers.sh"

TMPDIR_SMOKE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL [$label]"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    exit 1
  fi
}

# Case 1: truncated log with marker names in body but no anchored verdict line → UNKNOWN
F1="$TMPDIR_SMOKE/case1.txt"
cat > "$F1" <<'EOF'
Some log output
- Add verdict marker check (REVIEW_PASS/REVIEW_FAIL/**Status:** DONE/**Status:** BLOCKED) before transport
More lines here
EOF
assert_eq "case1 truncated-UNKNOWN" "UNKNOWN" "$(bash "$PARSE" status "$F1")"

# Case 2: **Status:** DONE on its own line at end → DONE
F2="$TMPDIR_SMOKE/case2.txt"
cat > "$F2" <<'EOF'
Some work was done
**Status:** DONE
EOF
assert_eq "case2 status-DONE" "DONE" "$(bash "$PARSE" status "$F2")"

# Case 3: **Status:** DONE in middle, then 20 lines of filler (pushes out of 15-line window) → UNKNOWN
F3="$TMPDIR_SMOKE/case3.txt"
{
  echo "**Status:** DONE"
  for i in $(seq 1 20); do echo "filler line $i"; done
} > "$F3"
assert_eq "case3 status-outside-window" "UNKNOWN" "$(bash "$PARSE" status "$F3")"

# Case 4: REVIEW_PASS alone on last line → REVIEW_PASS
F4="$TMPDIR_SMOKE/case4.txt"
cat > "$F4" <<'EOF'
Review complete
REVIEW_PASS
EOF
assert_eq "case4 review-PASS" "REVIEW_PASS" "$(bash "$PARSE" review "$F4")"

# Case 5: REVIEW_PASS with trailing comment → UNKNOWN (not a clean standalone line)
F5="$TMPDIR_SMOKE/case5.txt"
cat > "$F5" <<'EOF'
Review complete
REVIEW_PASS   # 无 CRITICAL/MAJOR
EOF
assert_eq "case5 review-PASS-with-comment" "UNKNOWN" "$(bash "$PARSE" review "$F5")"

# Case 6: REVIEW_FAIL then REVIEW_PASS → last wins = REVIEW_PASS
F6="$TMPDIR_SMOKE/case6.txt"
cat > "$F6" <<'EOF'
First pass
REVIEW_FAIL
Second pass
REVIEW_PASS
EOF
assert_eq "case6 last-verdict-wins" "REVIEW_PASS" "$(bash "$PARSE" review "$F6")"

# Edge 1: file does not exist → UNKNOWN, exit code 0
MISSING="$TMPDIR_SMOKE/no_such_file.txt"
if RESULT="$(bash "$PARSE" status "$MISSING")"; then
  RC=0
else
  RC=$?
fi
assert_eq "edge1 missing-file-status" "UNKNOWN" "$RESULT"
assert_eq "edge1 missing-file-status-exit" "0" "$RC"
if RESULT="$(bash "$PARSE" review "$MISSING")"; then
  RC=0
else
  RC=$?
fi
assert_eq "edge1 missing-file-review" "UNKNOWN" "$RESULT"
assert_eq "edge1 missing-file-review-exit" "0" "$RC"

# Edge 2: Chinese colon Status：DONE → DONE
F7="$TMPDIR_SMOKE/case7.txt"
printf 'Status：DONE\n' > "$F7"
assert_eq "edge2 chinese-colon" "DONE" "$(bash "$PARSE" status "$F7")"

echo "PASS smoke-parse-markers.sh"
