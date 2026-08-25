# composer-license-audit-action

Composite action to summarize Composer dependency licenses, surface allowlist status, and fail builds when a package has no license in the allowlist.

## Input options
- `composer-path` (default: `composer`): Path to the Composer executable. Useful when Composer is installed in a non-standard location.
- `use-locked` (default: `"false"`): When `true`, runs `composer licenses --locked` to read from `composer.lock` instead of installed packages. Use this for deterministic checks in CI.
- `allowed-licenses` (default not set): YAML-style multiline allowlist. When set, packages are marked ✅/❌ based on whether at least one of their licenses appears in the list (Composer treats multiple licenses on a package as alternatives you may choose from, so a `BSD-3-Clause OR GPL-2.0-only` package passes an allowlist containing `BSD-3-Clause`). Example:
  ```yaml
  allowed-licenses: |
    - MIT
    - Apache-2.0
    - BSD-3-Clause
  ```
  Entries are matched literally against the identifiers Composer reports. A package that declares its license as a single SPDX expression string (`"license": "(LGPL-2.1-only or GPL-3.0-or-later)"`, the only way Composer can express an `and` combination) is reported as that one string and is not parsed; it fails the allowlist unless the exact string is listed. This form is rare in practice.
- `fail-hard` (default: `"true"`): When `true` and `allowed-licenses` is set, the action exits non-zero if any package has no license in the allowlist. Set to `"false"` to only report status without failing.

## Pull request behavior
- On pull_request events, the action compares the current `composer.lock` to the PR base and adds a “New Packages” summary showing added packages, their licenses, and allowlist status (when configured).
- Override the base commit by setting the `PR_BASE_SHA` environment variable (handy for local testing or custom base refs).
