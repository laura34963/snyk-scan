# Project Overview — `snyk-scan-to-csv`

> **Type:** Explanation
> **Audience:** Developers, AI assistants, and any tooling that needs project context
> **Last updated:** 2026-07-23
>
> What this tool is, how it is built, and how it fits into the surrounding tooling — a single Bash + jq utility that runs Snyk's open-source dependency scan across several service repos and pivots the results into one compliance matrix CSV.
>
> Related docs:
> - Data structures & the CSV matrix model: [`domain-models.md`](domain-models.md)
> - Conventions for changing this code: [`coding-style.md`](coding-style.md)
> - External-tool dependencies (Snyk CLI, jq, brew/npm): [`integrations.md`](integrations.md)

---

<a id="1-purpose-scope"></a>

## 1. Purpose & Scope

`snyk-scan-to-csv` scans third-party dependencies (**Software Composition Analysis**,
`snyk test`) across multiple service repositories, then pivots every service's
results into a single package×service matrix CSV. The CSV layout matches the annual
compliance report **`[復掃] 開源套件漏洞檢查 (Snyk Scan)`**.

The tool covers **only** the open-source dependency scan. It deliberately does *not*
run:

- SAST (`snyk code test`),
- container / image scans, or
- IaC scans.

Those are separate compliance categories. The tool also does not auto-fill the
`No Fix Reason` column (filled in manually later), upload to any external system, or
diff against a previous report.

---

<a id="2-tech-stack"></a>

## 2. Tech Stack

| Concern | Choice | Notes |
|---|---|---|
| Orchestration | Bash | Written to be **Bash 3.2-compatible** (macOS default): no associative arrays, no `mapfile`/`readarray`, no `${var,,}`. See [`coding-style.md` §1](coding-style.md#1-language-bash-3-2-baseline). |
| JSON→CSV conversion | `jq` | All conversion logic lives in `lib/build_csv.jq`; required, not auto-installed. |
| Scanner | Snyk CLI | Invoked once per service repo; auto-installed via `brew`/`npm` if missing. |
| Config format | JSON | Read natively by `jq` — no `yq` dependency. |
| Tests | Plain Bash | A hand-rolled runner in `tests/run_tests.sh`; **no `bats`** or other test framework. |

There is no application datastore, no HTTP server, and no long-running process — this
is a one-shot local CLI.

---

<a id="3-architecture-overview"></a>

## 3. Architecture Overview

A single entrypoint script (`snyk-scan-to-csv.sh`) holds sourceable Bash functions
(config resolution, prerequisite bootstrap, resumable scan loop, report assembly)
plus a standalone jq program (`lib/build_csv.jq`) that transforms the collected
per-service Snyk JSON into the CSV. **All orchestration lives in Bash; all conversion
logic lives in jq.**

`main()` runs only when the script is *executed*, not when it is *sourced*, so the
test suite can source the file and call individual functions directly.

```
        (bootstrap: install snyk if missing, require jq, check auth)
JSON config (services→paths, options) ─┐
CLI args (override / add services) ─────┼──► resolve service list (ordered)
--discover <dir> (auto-detect repos) ───┘            │
                                                      │
              for each service:  snyk test --severity-threshold=high \
                                   --all-projects --exclude=<list> --json
                                   (skipped if <service>.json already exists)
                                                      │  atomic write
                                                      ▼
                            <dest>/<YYYYMMDD>/<service>.json   (raw, kept)
                                                      │
                     jq normalize + pivot over all <service>.json
                                                      ▼
                    <dest>/<YYYYMMDD>/snyk-report-<YYYYMMDD>.csv
```

The pipeline runs in four phases, all sequenced inside `main()`:

| Phase | Function(s) | Responsibility |
|---|---|---|
| **Resolve** | `parse_args`, `load_config`, `resolve_config`, `resolve_services` | Build the ordered `(service_name → repo_path)` list and options from CLI + config + discovery. |
| **Bootstrap** | `ensure_tools` (`ensure_jq`, `ensure_snyk`, `check_auth`) | Ensure `jq` and `snyk` are present and Snyk is authenticated. Skipped for `--convert-only` (only `ensure_jq` runs). |
| **Scan** | `run_scans` → `scan_service` (per service) | Run Snyk per repo, write raw JSON atomically, resume on rerun. |
| **Convert** | `build_report` → `lib/build_csv.jq` | Assemble per-service JSON into the matrix CSV. |

The exact data shapes flowing through this pipeline are documented in
[`domain-models.md`](domain-models.md).

---

<a id="4-directory-layout"></a>

## 4. Directory & Module Layout

| Path | Purpose |
|---|---|
| `snyk-scan-to-csv.sh` | The entrypoint and all Bash orchestration functions. Source-safe (see [`coding-style.md` §2](coding-style.md#2-set-e-discipline-source-safety)). |
| `lib/build_csv.jq` | The standalone jq program that pivots collected JSON into the CSV. The heart of the tool and its most testable unit. |
| `tests/run_tests.sh` | Plain-bash test runner and all test cases. |
| `tests/fixtures/` | Sample Snyk JSON (`member_center.json`, `store_center.json`), a `config.json`, and the golden `expected-report.csv`. |
| `tests/mocks/snyk` | A mock Snyk CLI driven by env vars, used by the scan and end-to-end tests. |
| `snyk-scan.config.example.json` | Sample config committed for reference. |
| `snyk-scan.config.json` | The operator's real config (services → absolute repo paths). Contains local machine paths. |
| `README.md` | Operator-facing usage, prerequisites, examples. |
| `out/` | **Generated** output; date-nested run artifacts. Not source. |

---

<a id="5-execution-model"></a>

## 5. Execution Model & Configuration

### 5.1 Invocation

The tool is invoked directly. Three ways to supply the service list, which merge:

```bash
./snyk-scan-to-csv.sh --config snyk-scan.config.json      # from a JSON config
./snyk-scan-to-csv.sh --service member_center=/repos/mc   # explicit, repeatable
./snyk-scan-to-csv.sh --discover /repos                   # auto-discover subdirs
```

### 5.2 Configuration precedence

Every option resolves with **CLI value > config-file value > built-in default**
(`resolve_config`). Defaults: severity `high`, dest `./out`, exclude `.ruby-lsp`.
The three-tier variable model that implements this is documented in
[`domain-models.md` §2](domain-models.md#2-configuration-resolution-model).

### 5.3 Injected clock

The run date comes from `${SNYK_SCAN_DATE:-$(date +%Y%m%d)}`, so tests can pin a
deterministic date. `DATE` (e.g. `20260721`) drives the output folder and CSV
filename; `DATE_SLASH` (`2026/07/21`) is the value in the CSV's date header cell.

---

<a id="6-output-layout"></a>

## 6. Output Layout

Regardless of `--dest`, all files for a run are written under a `YYYYMMDD` subfolder:

```
<dest>/<YYYYMMDD>/<service>.json               # raw Snyk output per service (kept)
<dest>/<YYYYMMDD>/snyk-report-<YYYYMMDD>.csv    # the matrix CSV
<dest>/<YYYYMMDD>/scan.log                      # per-service Snyk stderr (appended)
```

Example for 2026-07-21 with the default dest: `./out/20260721/…`.

---

<a id="7-resume-atomicity"></a>

## 7. Resume & Atomicity Semantics

The scan loop is resumable and idempotent:

- **Resume:** if `<dest>/<YYYYMMDD>/<service>.json` already exists, that service's
  Snyk call is skipped (logged). A run interrupted partway resumes without repeating
  completed scans.
- **Atomic writes:** each scan writes to a hidden `.<service>.json.tmp` and is renamed
  to `<service>.json` only when the result is usable. An interrupted scan therefore
  never leaves a truncated file that a rerun would wrongly treat as complete.
- **`--force`** ignores existing JSON and re-scans everything.
- **`--convert-only`** rebuilds the CSV from whatever JSON is already present, without
  running Snyk (and without requiring Snyk to be installed).

A single service failing to scan does not abort the run: its column is still emitted
(empty) so the matrix stays column-aligned, and the loop continues. See
[`domain-models.md` §5](domain-models.md#5-scan-outcome-state-machine) for the exact
outcome states.

---

<a id="8-integration-topology"></a>

## 8. Integration Topology

This tool is a **leaf CLI**: nothing calls into it (no upstream consumers, no exposed
API or queue), and its only outbound dependencies are external command-line tools and
the Snyk SaaS backend that the Snyk CLI talks to. Because the integration surface is
entirely external-tool-based rather than service-to-service, it is documented in a
dedicated file: see [`integrations.md`](integrations.md) for the Snyk CLI exit-code
contract, authentication probe, and the `brew`/`npm` install fallback.

---

<a id="9-running-it"></a>

## 9. Running It & the Tests

Run the tool (see [§5](#5-execution-model) for options). Run the test suite with:

```bash
bash tests/run_tests.sh
```

The runner exits non-zero if any test fails and prints a `PASS=<n> FAIL=<n>` summary.
Test conventions (fixtures, the env-driven mock Snyk, subshell isolation) are covered
in [`coding-style.md` §7](coding-style.md#7-testing-conventions).
