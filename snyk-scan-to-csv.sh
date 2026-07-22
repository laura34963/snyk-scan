#!/usr/bin/env bash
# snyk-scan-to-csv: run Snyk SCA across service repos, pivot to a matrix CSV.
# NOTE: `set -euo pipefail` is enabled inside main() only, so this file is
# safe to `source` from tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_die() { echo "ERROR: $*" >&2; exit 1; }
_log() { echo ">> $*" >&2; }

# ---- resolved globals (defaults filled in resolve_config) ----
CONFIG_FILE=""; DEST=""; SEVERITY=""; DISCOVER_ROOT=""; FORCE=0; CONVERT_ONLY=0
SERVICE_NAMES=(); SERVICE_PATHS=(); EXCLUDES=()

# ---- CLI-captured values (empty string / 0 = not set) ----
CLI_DEST=""; CLI_SEVERITY=""; CLI_DISCOVER=""; CLI_FORCE=0; CLI_CONVERT_ONLY=0
CLI_SERVICE_NAMES=(); CLI_SERVICE_PATHS=(); CLI_EXCLUDES=(); CLI_EXCLUDE_SET=0

# ---- config-file-captured values ----
CFG_SEVERITY=""; CFG_DEST=""; CFG_DISCOVER=""
CFG_SERVICE_NAMES=(); CFG_SERVICE_PATHS=(); CFG_EXCLUDES=(); CFG_HAS_EXCLUDE=false

usage() {
  cat >&2 <<'EOF'
Usage: snyk-scan-to-csv.sh [options]
  --config <file>         JSON config (default ./snyk-scan.config.json if present)
  --service name=path     Add/override one service (repeatable)
  --discover <dir>        Auto-discover services under <dir>
  --severity high|medium|all   Severity threshold (default high)
  --exclude <name>        Add a Snyk --exclude entry (repeatable)
  --dest <dir>            Base output dir (default ./out); files go under <dir>/<YYYYMMDD>/
  --force                 Re-scan even if <service>.json already exists
  --convert-only          Skip scanning; rebuild CSV from existing JSON
  -h, --help              Show this help
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)   CONFIG_FILE="$2"; shift 2 ;;
      --service)  CLI_SERVICE_NAMES+=("${2%%=*}"); CLI_SERVICE_PATHS+=("${2#*=}"); shift 2 ;;
      --discover) CLI_DISCOVER="$2"; shift 2 ;;
      --severity) CLI_SEVERITY="$2"; shift 2 ;;
      --exclude)  CLI_EXCLUDES+=("$2"); CLI_EXCLUDE_SET=1; shift 2 ;;
      --dest)     CLI_DEST="$2"; shift 2 ;;
      --force)    CLI_FORCE=1; shift ;;
      --convert-only) CLI_CONVERT_ONLY=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) _die "Unknown argument: $1 (see --help)" ;;
    esac
  done
}

load_config() {
  if [ -z "$CONFIG_FILE" ] && [ -f "./snyk-scan.config.json" ]; then
    CONFIG_FILE="./snyk-scan.config.json"
  fi
  [ -z "$CONFIG_FILE" ] && return 0
  [ -f "$CONFIG_FILE" ] || _die "Config file not found: $CONFIG_FILE"
  jq empty "$CONFIG_FILE" 2>/dev/null || _die "Config file is not valid JSON: $CONFIG_FILE"
  CFG_SEVERITY="$(jq -r '.severity // empty' "$CONFIG_FILE")"
  CFG_DEST="$(jq -r '.dest // empty' "$CONFIG_FILE")"
  CFG_DISCOVER="$(jq -r '.discover_root // empty' "$CONFIG_FILE")"
  CFG_HAS_EXCLUDE="$(jq -r 'has("exclude")' "$CONFIG_FILE")"
  local k v e
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] && continue
    CFG_SERVICE_NAMES+=("$k"); CFG_SERVICE_PATHS+=("$v")
  done < <(jq -r '.services // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG_FILE")
  while IFS= read -r e; do
    [ -n "$e" ] && CFG_EXCLUDES+=("$e")
  done < <(jq -r '.exclude // [] | .[]' "$CONFIG_FILE")
}

service_exists() {
  local i
  [ "${#SERVICE_NAMES[@]}" -eq 0 ] && return 1
  for i in $(seq 0 $(( ${#SERVICE_NAMES[@]} - 1 )) ); do
    [ "${SERVICE_NAMES[$i]}" = "$1" ] && return 0
  done
  return 1
}

upsert_service() { # $1 name  $2 path
  local i
  if [ "${#SERVICE_NAMES[@]}" -gt 0 ]; then
    for i in $(seq 0 $(( ${#SERVICE_NAMES[@]} - 1 )) ); do
      if [ "${SERVICE_NAMES[$i]}" = "$1" ]; then SERVICE_PATHS[$i]="$2"; return 0; fi
    done
  fi
  SERVICE_NAMES+=("$1"); SERVICE_PATHS+=("$2")
}

has_manifest() { # $1 dir
  local d="$1" m
  for m in Gemfile package.json requirements.txt go.mod pyproject.toml pom.xml build.gradle composer.json; do
    [ -f "$d/$m" ] && return 0
  done
  return 1
}

discover_services() { # $1 root -> echoes "name=path" lines
  local root="$1" d name
  [ -d "$root" ] || { _log "discover: root not found: $root"; return 0; }
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    has_manifest "$d" && echo "$name=${d%/}"
  done
}

resolve_services() {
  SERVICE_NAMES=(); SERVICE_PATHS=()
  local i line name path
  if [ "${#CFG_SERVICE_NAMES[@]}" -gt 0 ]; then
    for i in $(seq 0 $(( ${#CFG_SERVICE_NAMES[@]} - 1 )) ); do
      upsert_service "${CFG_SERVICE_NAMES[$i]}" "${CFG_SERVICE_PATHS[$i]}"
    done
  fi
  if [ "${#CLI_SERVICE_NAMES[@]}" -gt 0 ]; then
    for i in $(seq 0 $(( ${#CLI_SERVICE_NAMES[@]} - 1 )) ); do
      upsert_service "${CLI_SERVICE_NAMES[$i]}" "${CLI_SERVICE_PATHS[$i]}"
    done
  fi
  if [ -n "$DISCOVER_ROOT" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      name="${line%%=*}"; path="${line#*=}"
      service_exists "$name" || upsert_service "$name" "$path"
    done < <(discover_services "$DISCOVER_ROOT")
  fi
  [ "${#SERVICE_NAMES[@]}" -gt 0 ] || \
    _die "No services to scan. Provide --service, a config 'services' map, or --discover."
}

resolve_config() {
  SEVERITY="${CLI_SEVERITY:-${CFG_SEVERITY:-high}}"
  case "$SEVERITY" in high|medium|all) ;; *) _die "Invalid severity: $SEVERITY (use high|medium|all)";; esac
  DEST="${CLI_DEST:-${CFG_DEST:-./out}}"
  DISCOVER_ROOT="${CLI_DISCOVER:-${CFG_DISCOVER:-}}"
  FORCE="$CLI_FORCE"; CONVERT_ONLY="$CLI_CONVERT_ONLY"
  EXCLUDES=()
  if [ "$CLI_EXCLUDE_SET" = "1" ]; then
    [ "${#CLI_EXCLUDES[@]}" -gt 0 ] && EXCLUDES=("${CLI_EXCLUDES[@]}")
  elif [ "$CFG_HAS_EXCLUDE" = "true" ]; then
    [ "${#CFG_EXCLUDES[@]}" -gt 0 ] && EXCLUDES=("${CFG_EXCLUDES[@]}")
  else
    EXCLUDES=(".ruby-lsp")
  fi
  resolve_services
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 || _die "jq is required but not installed. Install it: brew install jq"
}

install_snyk() {
  if command -v brew >/dev/null 2>&1; then
    _log "snyk not found; installing via Homebrew..."; brew install snyk
  elif command -v npm >/dev/null 2>&1; then
    _log "snyk not found; installing via npm..."; npm install -g snyk
  else
    _die "snyk not found and neither 'brew' nor 'npm' available. Install manually: https://docs.snyk.io/snyk-cli/install-the-snyk-cli"
  fi
  command -v snyk >/dev/null 2>&1 || _die "snyk installation appears to have failed."
}

ensure_snyk() { command -v snyk >/dev/null 2>&1 || install_snyk; }

check_auth() {
  [ -n "$(snyk config get api 2>/dev/null)" ] || snyk whoami >/dev/null 2>&1 \
    || _die "Snyk is not authenticated. Run: snyk auth"
}

ensure_tools() { ensure_jq; ensure_snyk; check_auth; }

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