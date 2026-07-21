#!/usr/bin/env bash
# Plain-bash test runner (no bats dependency). Exits non-zero if any test fails.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures"
PASS=0; FAIL=0

assert_eq() { # $1 label $2 expected $3 actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"; fi
}
assert_rc() { # $1 label $2 expected_rc $3 actual_rc
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1 (expected rc=$2, got rc=$3)"; fi
}

test_build_csv_jq() {
  local combined out
  combined="$(mktemp)"
  { jq -c --arg s member_center '{service:$s,report:.}' "$FIX/member_center.json"
    jq -c --arg s store_center  '{service:$s,report:.}' "$FIX/store_center.json"
    jq -cn --arg s cr_system '{service:$s,report:null}'
  } | jq -s '.' > "$combined"
  out="$(jq -r --arg date "2026/07/21" --arg ver "1.1306.1" \
        -f "$ROOT/lib/build_csv.jq" "$combined")"
  rm -f "$combined"
  assert_eq "build_csv.jq matches expected-report.csv" \
    "$(cat "$FIX/expected-report.csv")" "$out"
}

test_build_csv_jq

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]