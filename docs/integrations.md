# Integrations — `snyk-scan-to-csv`

> **Type:** Reference
> **Audience:** Developers, AI assistants, and any tooling that needs project context
> **Last updated:** 2026-07-23
>
> The external tools and systems this CLI depends on, and the contract on each link. This tool has no inter-service (HTTP/queue) topology — its integration surface is entirely external command-line tools plus the Snyk SaaS backend the Snyk CLI talks to.
>
> Related docs:
> - How these dependencies sit in the pipeline: [`project-overview.md` §8](project-overview.md#8-integration-topology)
> - The scan-outcome contract that interprets Snyk's exit codes: [`domain-models.md` §5](domain-models.md#5-scan-outcome-state-machine)

---

<a id="1-topology"></a>

## 1. Topology

```
                     ┌───────────────────────────────────────────────┐
                     │            snyk-scan-to-csv.sh                 │
                     └───────────────────────────────────────────────┘
                          │            │              │
              exec (per   │            │ pipe JSON    │ bootstrap install
              service)    ▼            ▼              ▼   (if snyk missing)
                     ┌─────────┐   ┌────────┐   ┌──────────────┐
                     │  snyk   │   │   jq   │   │ brew  /  npm │
                     │  CLI    │   └────────┘   └──────────────┘
                     └─────────┘
                          │  reads service repo (cwd)
                          │  ── HTTPS ──▶  Snyk SaaS (vulnerability DB + auth)
```

There are **no upstream callers**: nothing imports, sources (outside the test suite),
or invokes this tool as a dependency. It is a leaf CLI run by an operator.

---

<a id="2-downstream-dependencies"></a>

## 2. Downstream Dependencies

| Dependency | Kind | How it is invoked | Purpose | Failure behavior |
|---|---|---|---|---|
| **Snyk CLI** | External binary | `( cd "$path" && snyk "${SNYK_ARGS[@]}" )` per service; `snyk --version`, `snyk config get api`, `snyk whoami`, `snyk auth` for bootstrap. | Runs the SCA scan and emits per-project JSON. | Non-zero exit is interpreted, not blindly failed — see [§3](#3-snyk-cli-contract). A per-service failure logs to `scan.log` and leaves the column empty; the run continues. |
| **jq** | External binary | Config parsing (`jq empty`, `jq -r '.severity // empty'`, …) and the whole conversion (`jq -j … -f lib/build_csv.jq`). | Parse JSON config; normalize + pivot Snyk JSON into CSV. | **Required, not auto-installed.** `ensure_jq` `_die`s with `brew install jq` if absent — jq is core to conversion, so silent auto-install is deliberately avoided. |
| **Homebrew (`brew`)** | Package manager | `brew install snyk` in `install_snyk`. | Preferred way to auto-install Snyk on the macOS host. | Tried first when `snyk` is missing. |
| **npm** | Package manager | `npm install -g snyk` in `install_snyk`. | Fallback Snyk installer when `brew` is unavailable. | Used only if `brew` is absent; if both are absent, `_die` with manual-install guidance. |
| **Snyk SaaS backend** | Remote HTTPS service | Reached transitively by the Snyk CLI. | Vulnerability database and authentication. | The tool never calls it directly; auth is verified locally before scanning (see [§4](#4-authentication)). |

The exact Snyk command assembled by `build_snyk_args`:

```
snyk test --severity-threshold=high --all-projects --exclude=.ruby-lsp --json
```

- The `--severity-threshold` flag is **omitted** when severity is `all`.
- `--exclude=<comma-joined>` is **omitted** when the exclude list is empty.
- `--all-projects` catches multiple manifests in one repo (see
  [`domain-models.md` §3](domain-models.md#3-snyk-report-shape)).

---

<a id="3-snyk-cli-contract"></a>

## 3. Snyk CLI Exit-Code Contract

`scan_service` treats Snyk's exit code specially, because Snyk exits non-zero *by
design* when it finds vulnerabilities:

| Snyk exit code | Meaning | Treated as |
|---|---|---|
| `0` | Scan ran, no vulnerabilities at/above threshold. | **Success** — JSON written. |
| `1` | Scan ran, vulnerabilities found. | **Success** — JSON written (this is the common case). |
| any other (e.g. `2`, `3`) | Real error (no manifest, auth/network failure, etc.). | **Failure** — `.tmp` discarded, no `<service>.json`, column left empty. |

Beyond the exit code, output MUST also be **valid JSON and not an error object**:

```bash
jq -e 'if type=="object" and has("error") then false else true end' "$tmp"
```

So a `0`/`1` exit that nonetheless produced `{"error": …}` is still treated as a
failure. Snyk stderr is appended to `<OUTDIR>/scan.log` for diagnosis.

---

<a id="4-authentication"></a>

## 4. Authentication

Authentication is the operator's responsibility and is verified before any scan
(`check_auth`), never performed automatically — installing the CLI does not
authenticate it:

```bash
[ -n "$(snyk config get api 2>/dev/null)" ] || snyk whoami >/dev/null 2>&1 \
  || _die "Snyk is not authenticated. Run: snyk auth"
```

The probe accepts either a stored API token (`snyk config get api`) or a live session
(`snyk whoami`). `--convert-only` runs skip this check entirely, since they never call
Snyk.

**Secret handling.** The stored token is only ever tested for presence
(`[ -n "$(…)" ]`) — its value is never echoed, logged, or written to output. New code
**must not** print the token.

---

<a id="5-version-provenance"></a>

## 5. Snyk Version Provenance

The CSV's row 1 records which Snyk CLI produced the report. The version is resolved
once, defensively, after the scan/convert branch in `main()`:

```bash
if command -v snyk >/dev/null 2>&1; then
  SNYK_VERSION="$(snyk --version 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
else
  SNYK_VERSION=""
fi
[ -n "$SNYK_VERSION" ] || SNYK_VERSION="unknown"
```

This is guarded so `--convert-only` succeeds even when Snyk is not installed at all —
in that case the report is stamped `Snyk CLI version unknown` (asserted by
`test_convert_only_without_snyk`).
