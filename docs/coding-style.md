# Coding Style — `snyk-scan-to-csv`

> **Type:** Reference / How-to
> **Audience:** Developers, AI assistants, and any tooling that needs project context
> **Last updated:** 2026-07-23
>
> Conventions and idioms that new code in this repository must follow. These are derived from the existing `snyk-scan-to-csv.sh`, `lib/build_csv.jq`, and `tests/run_tests.sh` — not from generic Bash advice.
>
> Related docs:
> - The data these conventions govern: [`domain-models.md`](domain-models.md)
> - The pipeline these functions form: [`project-overview.md` §3](project-overview.md#3-architecture-overview)

> **Terminology:** This document uses RFC 2119 keywords — **MUST** (mandatory),
> **SHOULD** (recommended), **MAY** (optional).

---

<a id="1-language-bash-3-2-baseline"></a>

## 1. Language: Bash 3.2 Baseline

The script MUST run on **Bash 3.2** (the macOS system default). This rules out several
common conveniences.

| Rule | Rationale |
|---|---|
| **MUST NOT** use associative arrays. | Not available in 3.2. Use *parallel indexed arrays* keyed by the same index (e.g. `SERVICE_NAMES[i]` / `SERVICE_PATHS[i]`). |
| **MUST NOT** use `mapfile` / `readarray`. | Not available in 3.2. Use `while IFS= read -r … done < <(…)` process substitution. |
| **MUST NOT** use `${var,,}` / `${var^^}` case conversion. | Not available in 3.2. |
| **MUST** guard every possibly-empty array before `"${arr[@]}"` expansion. | Under `set -u`, Bash 3.2 errors on expanding an empty array. Guard with `[ "${#arr[@]}" -gt 0 ]` first (see `run_scans`, `resolve_services`, `build_snyk_args`). |

```bash
# Bad — errors under set -u on Bash 3.2 when the array is empty
SNYK_ARGS+=("--exclude=${EXCLUDES[*]}")

# Good — guard the expansion (from build_snyk_args)
if [ "${#EXCLUDES[@]}" -gt 0 ]; then
  local IFS=,; SNYK_ARGS+=("--exclude=${EXCLUDES[*]}")
fi
```

Iteration over parallel arrays uses index ranges, not `for x in "${arr[@]}"`, so the
two arrays stay aligned:

```bash
for i in $(seq 0 $(( ${#SERVICE_NAMES[@]} - 1 )) ); do
  scan_service "${SERVICE_NAMES[$i]}" "${SERVICE_PATHS[$i]}" || fails=$((fails+1))
done
```

---

<a id="2-set-e-discipline-source-safety"></a>

## 2. `set -e` Discipline & Source-Safety

`set -euo pipefail` MUST be set **inside `main()` only**, never at file top level. The
test suite sources the script to call functions directly; enabling `errexit` at the
top would abort the sourcing shell on the first non-zero return.

The executed-vs-sourced guard at the bottom of the file MUST be preserved:

```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
```

**Snapshot-and-restore, don't force.** A function that must locally disable `errexit`
MUST snapshot whether `-e` was active on entry and restore *that* state — it MUST NOT
blindly `set -e` afterward, because the function is also called from tests where `-e`
is off, and forcing it on would leak into the caller. `scan_service` is the reference:

```bash
# Good — from scan_service: precise restore, no state leak
local had_e=0; case "$-" in *e*) had_e=1 ;; esac
set +e
( cd "$path" && snyk "${SNYK_ARGS[@]}" ) > "$tmp" 2>>"$OUTDIR/scan.log"
rc=$?
[ "$had_e" -eq 1 ] && set -e
```

---

<a id="3-naming-conventions"></a>

## 3. Naming Conventions

Global variables encode their **tier** in a prefix, so precedence is readable at a
glance (see [`domain-models.md` §2](domain-models.md#2-configuration-resolution-model)):

| Prefix | Meaning | Set by |
|---|---|---|
| `CLI_` | Value captured from a command-line flag | `parse_args` |
| `CFG_` | Value captured from the JSON config | `load_config` |
| *(no prefix)* | Final resolved value | `resolve_config` |

- Helper functions use a leading underscore for tiny cross-cutting utilities: `_die`,
  `_log`. New code **SHOULD** follow this only for the same class of one-line utilities.
- Function names describe the action (`resolve_services`, `has_manifest`,
  `build_snyk_args`, `scan_service`). New functions **SHOULD** match this verb-first,
  lower_snake_case style.

---

<a id="4-input-validation-at-boundaries"></a>

## 4. Input Validation at Boundaries

Untrusted input (CLI args, config values, service names) MUST be validated where it
enters, and rejected with a clear `_die` message rather than allowed to fail obscurely
later.

| Boundary | Rule (as implemented) |
|---|---|
| Value-taking flags | MUST require a value: `[ "$#" -ge 2 ] \|\| _die "$1 requires a value"` — avoids a raw `$2: unbound` abort under `set -u`. |
| `--service` | MUST be `name=path`; a value with no `=` is rejected. |
| `--severity` | MUST be one of `high\|medium\|all`; anything else is fatal. |
| Config file | MUST be valid JSON (`jq empty`) before any key is read. |
| Service name | MUST NOT be empty, `.`, `..`, or contain `/` — it becomes a path component and a CSV header (path-traversal guard). |

```bash
# Good — service name sanitization (from resolve_services)
case "${SERVICE_NAMES[$i]}" in
  ""|.|..|*/*) _die "Invalid service name: '${SERVICE_NAMES[$i]}' (…)";;
esac
```

New code that consumes external input **MUST** add an equivalent guard rather than
trusting shape.

---

<a id="5-error-handling-logging"></a>

## 5. Error Handling & Logging

- **Two channels, both to stderr.** `_die <msg>` prints `ERROR: …` and exits 1;
  `_log <msg>` prints `>> …` for progress. stdout is reserved for real output (e.g.
  `build_report` echoes the CSV path). New code **MUST NOT** print diagnostics to
  stdout.
- **Fail fast on defects, continue on per-item failure.** Missing prerequisites and
  invalid input `_die` immediately. A single service failing to scan **MUST NOT** abort
  the run: `run_scans` counts failures, logs a summary, and returns 0 so the report
  still builds (`scan_service` returns 1, the loop continues).
- **Atomic writes for durable output.** Any file a rerun might consume MUST be written
  to a temp path and `mv`'d into place only once known-good, so an interrupted run
  never leaves a truncated file that resume logic would trust. `scan_service` and
  `build_report` (`.parts`/`.combined` temps) both follow this.
- **Errors carry context.** `_die`/`_log` messages name the service and point at the
  fix (`see $OUTDIR/scan.log`, `Run: snyk auth`). New messages **SHOULD** do the same.

---

<a id="6-conversion-in-jq"></a>

## 6. Conversion Logic Lives in jq

All JSON→CSV transformation MUST live in `lib/build_csv.jq`; Bash only marshals files
in and out. Do not add data-shaping logic (filtering vulns, formatting cells) to the
Bash side.

- CSV quoting MUST be minimal / RFC 4180 via the `csvfield` helper — do **not** switch
  to jq's `@csv`, which always-quotes. (See
  [`domain-models.md` §6.3](domain-models.md#6-csv-matrix-model).)
- The report is emitted with `jq -j` (no trailing newline is added by jq; the program
  itself joins rows with `\n`). Keep this in mind when comparing output byte-for-byte
  in tests.
- Deduplication that must preserve order uses the local `dedup` def, not `unique`
  (which sorts). Package *keys* use `unique` intentionally (sorted rows); within a cell
  or issue block, order is preserved via `dedup`.

---

<a id="7-testing-conventions"></a>

## 7. Testing Conventions

Tests are plain Bash in `tests/run_tests.sh` — **no `bats`**. New behavior **MUST**
come with a test here, and **SHOULD** be added test-first (the implementation plan was
executed fail-first per TDD).

| Convention | Detail |
|---|---|
| Assertions | `assert_eq <label> <expected> <actual>` and `assert_rc <label> <expected_rc> <actual_rc>`; both bump `PASS`/`FAIL` counters. |
| Isolation | Each test runs its body in a `( … )` subshell, usually under `set +u`, so it can `source` the script and set globals without polluting other tests. |
| Determinism | The clock is injected via `SNYK_SCAN_DATE`; tests pin `20260721`. New time-dependent code **MUST** read the clock the same way, not call `date` directly. |
| Snyk mock | `tests/mocks/snyk` stands in for the real CLI, driven by env: `MOCK_FIXTURES` (dir of `<service>.json` matched by `$PWD` basename) and `MOCK_FAIL` (a service name that should exit non-zero). Prepend `tests/mocks` to `PATH` to activate it. |
| Golden file | `tests/fixtures/expected-report.csv` is the byte-exact expected CSV; both the jq-level and `build_report`-level tests diff against it. |
| Runner contract | The runner prints `PASS=<n> FAIL=<n>` and exits non-zero if any test failed. |

New tests **MUST** clean up their temp files/dirs (`mktemp -d`, `rm -rf` on exit of the
subshell) as the existing tests do.

> **Known non-hermeticity (verified 2026-07-23).** The suite is not fully isolated
> from the current working directory. `load_config` auto-adopts `./snyk-scan.config.json`
> when `CONFIG_FILE` is unset, so the config-resolution tests that expect *no* config
> (`test_resolve_defaults`, `test_discover`, `test_end_to_end`) **fail when the runner
> is invoked from the repo root**, because the committed `./snyk-scan.config.json` is
> picked up. They pass from any directory without that file. New config tests **SHOULD**
> neutralize this (e.g. run in a scratch `cwd`, or set `CONFIG_FILE` explicitly) rather
> than depend on the caller's directory. Classification: **(b) latent test bug** — the
> production auto-pickup behavior is intended; the tests just fail to isolate from it.
