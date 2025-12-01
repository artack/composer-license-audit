# composer-license-audit-action

Composite action to summarize Composer dependency licenses, surface allowlist status, and fail builds when disallowed licenses are present.

## Input options
- `composer-path` (default: `composer`): Path to the Composer executable. Useful when Composer is installed in a non-standard location.
- `use-locked` (default: `"false"`): When `true`, runs `composer licenses --locked` to read from `composer.lock` instead of installed packages. Use this for deterministic checks in CI.
- `allowed-licenses` (default not set): YAML-style multiline allowlist. When set, packages are marked ✅/❌ based on whether all their licenses appear in the list. Example:
  ```yaml
  allowed-licenses: |
    - MIT
    - Apache-2.0
    - BSD-3-Clause
  ```
- `fail-hard` (default: `"true"`): When `true` and `allowed-licenses` is set, the action exits non-zero if any package uses a license outside the allowlist. Set to `"false"` to only report status without failing.

## Pull request behavior
- On pull_request events, the action compares the current `composer.lock` to the PR base and adds a “New Packages” summary showing added packages, their licenses, and allowlist status (when configured).
- Override the base commit by setting the `PR_BASE_SHA` environment variable (handy for local testing or custom base refs).
