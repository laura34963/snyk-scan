# Domain Models — `snyk-scan-to-csv`

> **Type:** Reference
> **Audience:** Developers, AI assistants, and any tooling that needs project context
> **Last updated:** 2026-07-23
>
> The data structures this tool operates on. There is no database — the "models" here are the in-memory Bash state (services, resolved config), the shape of Snyk's JSON output as consumed, and the CSV matrix produced by `lib/build_csv.jq`.
>
> Related docs:
> - How these pieces fit into the pipeline: [`project-overview.md` §3](project-overview.md#3-architecture-overview)
> - Conventions governing this state: [`coding-style.md`](coding-style.md)

---

<a id="1-service"></a>

## 1. Service

A **service** is one repository to scan. It has exactly two attributes: a **name**
(used as a filesystem path component and a CSV column header) and a **path** (the
repo directory Snyk runs in).

Services are held in two **parallel indexed arrays** (Bash 3.2 has no associative
arrays), where index `i` in both arrays refers to the same service. Array order *is*
the CSV column order.

| Structure | Type | Purpose |
|---|---|---|
| `SERVICE_NAMES[i]` | string | Service name; becomes `<name>.json` and the column header. |
| `SERVICE_PATHS[i]` | string | Absolute/relative path to the repo Snyk scans. |

**Invariant — service name is a trust boundary.** Because the name becomes a path
component (`<OUTDIR>/<name>.json`) and a CSV header, `resolve_services` rejects any
name that is empty, `.`, `..`, or contains `/`, to prevent escaping the output
directory. See [`coding-style.md` §4](coding-style.md#4-input-validation-at-boundaries).

### 1.1 Where services come from

`resolve_services` builds the final list by upserting from three sources in this order
(later sources add new services but never reorder or displace earlier ones):

```
config "services" map ──▶ CLI --service entries ──▶ --discover results
   (insertion order)        (override path on         (only names not already
                             name match)                present are appended)
```

- Config and CLI entries **upsert**: a name already present has its path overwritten;
  a new name is appended.
- Discovered services are appended only if the name is not already present
  (`service_exists` guard) — explicit entries always win.
- `has_manifest` decides what `--discover` treats as a service: a subdirectory
  containing any of `Gemfile`, `package.json`, `requirements.txt`, `go.mod`,
  `pyproject.toml`, `pom.xml`, `build.gradle`, `composer.json`.

---

<a id="2-configuration-resolution-model"></a>

## 2. Configuration Resolution Model

Configuration flows through **three tiers of variables**, deliberately kept separate
so precedence is explicit rather than order-of-assignment magic. `resolve_config`
collapses them into the resolved tier.

| Tier | Prefix | Set by | Example vars |
|---|---|---|---|
| CLI-captured | `CLI_` | `parse_args` | `CLI_SEVERITY`, `CLI_DEST`, `CLI_SERVICE_NAMES[]`, `CLI_EXCLUDES[]`, `CLI_FORCE` |
| Config-file-captured | `CFG_` | `load_config` (via `jq`) | `CFG_SEVERITY`, `CFG_DEST`, `CFG_SERVICE_NAMES[]`, `CFG_EXCLUDES[]`, `CFG_HAS_EXCLUDE` |
| Resolved | *(none)* | `resolve_config` | `SEVERITY`, `DEST`, `DISCOVER_ROOT`, `FORCE`, `CONVERT_ONLY`, `EXCLUDES[]`, `SERVICE_NAMES[]`, `SERVICE_PATHS[]` |

### 2.1 Resolved fields

| Field | Type / values | Resolution rule |
|---|---|---|
| `SEVERITY` | `high` \| `medium` \| `all` | `CLI_SEVERITY` → `CFG_SEVERITY` → `high`. Validated; anything else is fatal. |
| `DEST` | string | `CLI_DEST` → `CFG_DEST` → `./out`. |
| `DISCOVER_ROOT` | string | `CLI_DISCOVER` → `CFG_DISCOVER` → empty. |
| `FORCE` | `0` \| `1` | `CLI_FORCE` only (no config key). |
| `CONVERT_ONLY` | `0` \| `1` | `CLI_CONVERT_ONLY` only (no config key). |
| `EXCLUDES[]` | string array | See §2.2 — three-way precedence with an explicit "set" flag. |

### 2.2 The `EXCLUDES` precedence subtlety

`EXCLUDES` cannot use plain `${A:-${B:-default}}` fallback because an *empty* exclude
list is a meaningful, intentional choice distinct from "not specified". Two flags
disambiguate:

- If `CLI_EXCLUDE_SET=1` (any `--exclude` was passed) → use the CLI list (even if the
  resulting array is empty is not possible via CLI, but the flag marks intent).
- Else if `CFG_HAS_EXCLUDE="true"` (the config JSON *has* an `"exclude"` key, even
  `[]`) → use the config list.
- Else → default to `(".ruby-lsp")`.

This lets a config author write `"exclude": []` to genuinely disable the default,
which a naive fallback would silently overwrite.

---

<a id="3-snyk-report-shape"></a>

## 3. Snyk Report Shape (consumed)

Each `<service>.json` is raw `snyk test --json` output. Because `--all-projects` is
used, a single repo may produce **one project object or an array of project objects**
(one per manifest, e.g. a `Gemfile` and a `package.json` in the same repo). The
converter's `vulns_of` normalizes all three possibilities into a flat vulnerability
list:

| `report` value | Meaning | Normalized to |
|---|---|---|
| `null` | No `<service>.json` file existed (service failed or was absent). | `[]` (empty — column still emitted) |
| single object | One project scanned. | that object's `.vulnerabilities` |
| array | Multiple projects (`--all-projects`). | every element's `.vulnerabilities`, concatenated |

An object with an `"error"` key is treated as a failed scan by `scan_service` and is
never written as `<service>.json` (see [§5](#5-scan-outcome-state-machine)).

---

<a id="4-vulnerability-record"></a>

## 4. Vulnerability Record

Each element of a project's `.vulnerabilities[]` is consumed for these fields only
(the tool ignores the rest of Snyk's rich vuln object):

| Field | Type | Used for |
|---|---|---|
| `packageName` | string | **The matrix row key.** One package = one row across all services. Version is intentionally *not* part of the key. |
| `version` | string | The installed version shown in that service's cell (`<pkg>@<version>`). |
| `identifiers.CVE[]` | string array | Preferred issue URLs: `https://cve.mitre.org/cgi-bin/cvename.cgi?name=<CVE>`. |
| `identifiers.GHSA[]` | string array | Used when there is no CVE: `https://github.com/advisories/<GHSA>`. |
| `fixedIn[]` | string array | Fix versions. Drives both the Issue-block `Fixed in …` line and the per-cell `Remediation Upgrade to …` line. Empty ⇒ `Not fixed`. |
| `url` | string | Fallback issue URL when neither CVE nor GHSA is present. |

**URL selection (`urls_of`)** is a strict fallback chain: CVE links if any CVE exists,
else GHSA links, else the single `url`.

**Remediation (`fixed_str` / `cell_for`)** derives fix versions from each vuln's own
`fixedIn`, taking the order-preserving union across a package's vulns within a service.
An empty `fixedIn` renders as `Fixed in <pkg>@Not fixed` in the Issue column and adds
no remediation line to the cell.

---

<a id="5-scan-outcome-state-machine"></a>

## 5. Scan Outcome State Machine

`scan_service <name> <path>` resolves to one of four terminal outcomes. "Usable" means
Snyk exited `0` (no vulns) or `1` (vulns found), the output is valid JSON, and it is
not an error object.

```
                    ┌─ target exists & FORCE≠1 ──▶ SKIP (cached)      return 0
                    │
scan_service ───────┼─ path not a directory ─────▶ FAIL (no path)    return 1
                    │
                    ├─ snyk usable ──(atomic mv .tmp → <name>.json)─▶ OK    return 0
                    │
                    └─ snyk unusable ──(rm .tmp)──▶ FAIL (rc/error)   return 1
```

`States: SKIP (cached), FAIL (no path), OK, FAIL (rc/error)`

- Snyk's exit code `1` (issues found) is **success** for this tool — it is
  distinguished from real errors (other exit codes, or a JSON `error` object).
- On any FAIL, no `<service>.json` is written; the converter then emits that service's
  column as empty via `report: null`. The matrix column count never changes.

---

<a id="6-csv-matrix-model"></a>

## 6. CSV Matrix Model

`lib/build_csv.jq` consumes an ordered array
`[ {service:string, report:(null|object|array)}, … ]` (column order) plus `$date`
(`YYYY/MM/DD`) and `$ver` (Snyk version string), and emits the full CSV.

### 6.1 Row structure

| Row(s) | Content |
|---|---|
| Row 1 | `Snyk CLI version <ver>` in column 1; all remaining cells empty. |
| Row 2 (header) | `<YYYY/MM/DD>`, `Issue`, `No Fix Reason`, then one column per service (in order). |
| Data rows | One per vulnerable package name, **sorted** (`unique` sorts). |

### 6.2 Data-row columns

| Column | Content |
|---|---|
| 1 — Package | The package name (the row key), e.g. `activestorage`. |
| 2 — Issue | For each unique CVE/advisory affecting the package: the URL, then a newline `Fixed in <pkg>@<fixes>` (or `…@Not fixed`). Blocks joined by newlines; order-preserving deduped. |
| 3 — No Fix Reason | Always emitted empty; filled in manually later. |
| 4+ — per-service cell | `<pkg>@<installedVersion>` and, when a fix exists, a newline `Remediation Upgrade to <pkg>@<fixedVersions>`. Empty when the package is not vulnerable in that service. |

### 6.3 CSV quoting

Quoting is **minimal / RFC 4180**, implemented by a custom `csvfield` function: a
field is quoted only if it contains `,`, `"`, CR, or LF (embedded `"` doubled);
`null` renders as an empty field. jq's built-in `@csv` is **not** used because it
always-quotes.

> **Discrepancy note (spec §3 vs code).** The design doc's §3 prose says the CSV is
> emitted "via `@csv` (RFC 4180 quoting)". The implementation deliberately does *not*
> use `@csv` — it uses the custom `csvfield` for minimal quoting, as the implementation
> plan's global constraints specify. Classification: **(a) spec imprecise/stale — code
> is authoritative.** The observable quoting behavior (RFC 4180) is the same; only the
> mechanism differs.

### 6.4 Worked example

The golden fixture `tests/fixtures/expected-report.csv` shows the shape, including:
`activestorage` appearing as one row aggregating two CVEs across `member_center` and
`store_center`; `angular` with `Fixed in angular@Not fixed`; and `cr_system` present
as a trailing empty column (its scan produced no JSON).
