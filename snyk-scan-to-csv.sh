#!/usr/bin/env bash
# snyk-scan-to-csv: run Snyk SCA across service repos, pivot to a matrix CSV.
# NOTE: `set -euo pipefail` is enabled inside main() only, so this file is
# safe to `source` from tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_die() { echo "ERROR: $*" >&2; exit 1; }
_log() { echo ">> $*" >&2; }

# Build <OUTDIR>/snyk-report-<DATE>.csv from the per-service JSON files.
# Missing <service>.json -> report:null -> empty column (still a column).
build_report() {
  local csv="$OUTDIR/snyk-report-$DATE.csv"
  local parts="$OUTDIR/.parts.$$.jsonl"
  local combined="$OUTDIR/.combined.$$.json"
  local i n f
  : > "$parts"
  for i in $(seq 0 $(( ${#SERVICE_NAMES[@]} - 1 )) ); do
    n="${SERVICE_NAMES[$i]}"; f="$OUTDIR/$n.json"
    if [ -f "$f" ]; then
      jq -c --arg s "$n" '{service:$s, report:.}' "$f" >> "$parts"
    else
      jq -cn --arg s "$n" '{service:$s, report:null}' >> "$parts"
    fi
  done
  jq -s '.' "$parts" > "$combined"
  jq -j --arg date "$DATE_SLASH" --arg ver "$SNYK_VERSION" \
     -f "$SCRIPT_DIR/lib/build_csv.jq" "$combined" > "$csv"
  rm -f "$parts" "$combined"
  _log "CSV written: $csv"
  echo "$csv"
}