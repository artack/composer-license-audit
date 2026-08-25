# Domain vocabulary

Terms used in code, tests and docs. One meaning each.

- **Audit result** — the single document produced by `src/audit.jq` from the licenses JSON, the allowlist and the base lock. Every allowed / new / violation decision is made there, once. Renderers only format it.
- **Allowlist** — the set of license identifiers a package may carry. A package is *allowed* if at least one of its licenses is in the allowlist (Composer lists multiple licenses as alternatives the consumer may choose from). Absent allowlist → no verdict (`allowed: null`), never a violation. `counts[].allowed` judges a single license, not a package: a license can be ❌ in the counts table while every package carrying it is ✅ through another license.
- **Base** — the `composer.lock` at the pull request's base commit. Used only to decide which packages are *new*. Absent or empty base → no verdict (`is_new: null`).
- **New package** — a package present in the audited project but not in the base lock (`packages` or `packages-dev`).
- **Violation** — a package whose `allowed` is `false`. `has_violations` is the only input to the exit code (together with `fail-hard`).
- **Renderers** — the three consumers of the audit result: the **log** (stdout), the **step summary** (`GITHUB_STEP_SUMMARY`) and the **PR comment** (GitHub issues API). They must not re-derive any verdict.
