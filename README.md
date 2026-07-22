# snyk-scan-to-csv

Runs Snyk's third-party dependency scan (`snyk test`, SCA — **not** `snyk code`
SAST or container scans) across multiple service repos and pivots the results
into a package×service matrix CSV matching `[復掃] 開源套件漏洞檢查 (Snyk Scan)`.

## Prerequisites

- `jq` (`brew install jq`)
- Snyk CLI — auto-installed via `brew`/`npm` if missing. **You must authenticate
  once:** `snyk auth`.

## Usage

```bash
# From a JSON config
./snyk-scan-to-csv.sh --config snyk-scan.config.json

# Explicit services on the CLI
./snyk-scan-to-csv.sh \
  --service member_center=/repos/member_center \
  --service store_center=/repos/store_center

# Auto-discover every repo under a parent directory
./snyk-scan-to-csv.sh --discover /repos
```

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `--config <file>` | `./snyk-scan.config.json` if present | JSON config |
| `--service name=path` | — | Add/override a service (repeatable) |
| `--discover <dir>` | — | Treat each manifest-bearing subdir as a service |
| `--severity high\|medium\|all` | `high` | Severity threshold |
| `--exclude <name>` | `.ruby-lsp` | Snyk `--exclude` entry (repeatable) |
| `--dest <dir>` | `./out` | Base output dir |
| `--force` | off | Re-scan even if `<service>.json` exists |
| `--convert-only` | off | Rebuild CSV from existing JSON, no scanning |

CLI values override config values, which override built-in defaults.

## Output

All output is written under a date subfolder, regardless of `--dest`:

```
<dest>/<YYYYMMDD>/<service>.json          # raw Snyk output per service (kept)
<dest>/<YYYYMMDD>/snyk-report-<YYYYMMDD>.csv
<dest>/<YYYYMMDD>/scan.log                 # per-service stderr
```

The Snyk command per service is:

```
snyk test --severity-threshold=high --all-projects --exclude=.ruby-lsp --json
```

## Resume behavior

If `<service>.json` already exists in the date folder, that service is skipped —
so a run interrupted partway resumes without repeating completed scans. Scans are
written atomically (temp file renamed on success), so an interrupted scan never
leaves a truncated file. Use `--force` to re-scan everything, or `--convert-only`
to rebuild just the CSV.

## Tests

```bash
bash tests/run_tests.sh
```
