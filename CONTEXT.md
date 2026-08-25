# Domain vocabulary

Terms used in code, tests and docs. One meaning each.

- **Audit result** — the single document produced by `src/audit.jq` from the licenses JSON, the allowlist and the base lock. Every allowed / new / violation decision is made there, once. Renderers only format it.
- **Allowlist** — the set of license identifiers a package may carry. A package is *allowed* if at least one of its licenses is in the allowlist (Composer lists multiple licenses as alternatives the consumer may choose from). Absent allowlist → no verdict (`allowed: null`), never a violation. `counts[].status` judges a single license in the light of the packages carrying it: *allowed* (in the allowlist), *blocking* (not in the allowlist and carried by at least one package that is not allowed), *alternative* (not in the allowlist, but every package carrying it is allowed through another license). A license is *blocking* exactly when there is a violation it takes part in.
- **Base** — the `composer.lock` at the pull request's base commit. Used only to decide which packages are *new*. Absent or empty base → no verdict (`is_new: null`).
- **New package** — a package present in the audited project but not in the base lock (`packages` or `packages-dev`).
- **Violation** — a package whose `allowed` is `false`; every license of such a package is *blocking*. `has_violations` is the only input to the exit code (together with `fail-hard`).
- **Renderers** — the three consumers of the audit result: the **log** (stdout), the **step summary** (`GITHUB_STEP_SUMMARY`) and the **PR comment** (GitHub issues API). They must not re-derive any verdict.
