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

test_build_report() {
  # shellcheck disable=SC1090
  ( set +u
    source "$ROOT/snyk-scan-to-csv.sh"
    SCRIPT_DIR="$ROOT"
    OUTDIR="$(mktemp -d)"
    DATE="20260721"; DATE_SLASH="2026/07/21"; SNYK_VERSION="1.1306.1"
    SERVICE_NAMES=(member_center store_center cr_system)   # cr_system has no json file
    cp "$FIX/member_center.json" "$OUTDIR/member_center.json"
    cp "$FIX/store_center.json"  "$OUTDIR/store_center.json"
    csv="$(build_report)"
    diff_out="$(diff "$FIX/expected-report.csv" "$csv" || true)"
    rm -rf "$OUTDIR"
    [ -z "$diff_out" ] && echo "BR_OK" || { echo "BR_DIFF"; echo "$diff_out"; }
  ) > /tmp/br_result.$$ 2>/dev/null
  assert_eq "build_report produces expected CSV (incl. empty column)" \
    "BR_OK" "$(head -1 /tmp/br_result.$$)"
  rm -f /tmp/br_result.$$
}

test_build_report

test_resolve_defaults() {
  ( set +u
    source "$ROOT/snyk-scan-to-csv.sh"
    parse_args --service api=/repos/api
    load_config; resolve_config
    echo "SEV=$SEVERITY DEST=$DEST EXC=${EXCLUDES[*]} N=${#SERVICE_NAMES[@]} S0=${SERVICE_NAMES[0]} P0=${SERVICE_PATHS[0]}"
  ) > /tmp/rd.$$ 2>/dev/null
  assert_eq "defaults: high sev, ./out dest, .ruby-lsp exclude, one CLI service" \
    "SEV=high DEST=./out EXC=.ruby-lsp N=1 S0=api P0=/repos/api" "$(cat /tmp/rd.$$)"
  rm -f /tmp/rd.$$
}

test_resolve_config_and_override() {
  ( set +u
    source "$ROOT/snyk-scan-to-csv.sh"
    # config sets severity=medium, dest=./cfg-out, two services; CLI overrides severity + adds/overrides service
    parse_args --config "$FIX/config.json" --severity high --service store_center=/override/store
    load_config; resolve_config
    echo "SEV=$SEVERITY DEST=$DEST N=${#SERVICE_NAMES[@]} NAMES=${SERVICE_NAMES[*]} STORE=${SERVICE_PATHS[1]} EXC=${EXCLUDES[*]}"
  ) > /tmp/rc.$$ 2>/dev/null
  assert_eq "config loaded; CLI overrides severity and store_center path" \
    "SEV=high DEST=./cfg-out N=2 NAMES=member_center store_center STORE=/override/store EXC=.ruby-lsp vendor" \
    "$(cat /tmp/rc.$$)"
  rm -f /tmp/rc.$$
}

test_discover() {
  ( set +u
    source "$ROOT/snyk-scan-to-csv.sh"
    root="$(mktemp -d)"
    mkdir -p "$root/svc_a" "$root/svc_b" "$root/not_a_repo"
    : > "$root/svc_a/Gemfile"; : > "$root/svc_b/package.json"
    parse_args --discover "$root"
    load_config; resolve_config
    echo "N=${#SERVICE_NAMES[@]} NAMES=${SERVICE_NAMES[*]}"
    rm -rf "$root"
  ) > /tmp/dd.$$ 2>/dev/null
  assert_eq "discover adds only subdirs with a manifest, sorted" \
    "N=2 NAMES=svc_a svc_b" "$(cat /tmp/dd.$$)"
  rm -f /tmp/dd.$$
}

test_resolve_defaults
test_resolve_config_and_override
test_discover

test_install_snyk_no_pkgmgr() {
  local err rc
  err="$(
    ( set +u
      source "$ROOT/snyk-scan-to-csv.sh"
      empty="$(mktemp -d)"          # PATH with neither brew nor npm nor snyk
      PATH="$empty" install_snyk
    ) 2>&1
  )"; rc=$?
  assert_rc "install_snyk fails when brew and npm are both absent" 1 "$rc"
  case "$err" in
    *"neither 'brew' nor 'npm'"*) PASS=$((PASS+1)); echo "ok   - install_snyk emits manual-install guidance" ;;
    *) FAIL=$((FAIL+1)); echo "FAIL - install_snyk guidance message"; echo "  got: $err" ;;
  esac
}

test_ensure_snyk_present() {
  local rc
  ( set +u
    source "$ROOT/snyk-scan-to-csv.sh"
    bin="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$bin/snyk"; chmod +x "$bin/snyk"
    PATH="$bin:$PATH" ensure_snyk
  ) >/dev/null 2>&1; rc=$?
  assert_rc "ensure_snyk is a no-op when snyk is already on PATH" 0 "$rc"
}

test_install_snyk_no_pkgmgr
test_ensure_snyk_present

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]