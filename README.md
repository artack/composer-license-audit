# composer-license-audit

Composite action that runs `composer licenses`, prints a license summary to the workflow log and the step summary, checks every package against an optional allowlist, and on pull requests reports which packages are new compared to the base branch. With an allowlist configured, the build fails when a package has no license in the allowlist.

## Usage

```yaml
on:
  pull_request:

permissions:
  contents: read
  pull-requests: write   # only needed for the PR comment

jobs:
  license-audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: shivammathur/setup-php@v2
        with:
          tools: composer
      - uses: artack/composer-license-audit@v0.1.0
        with:
          use-locked: "true"
          allowed-licenses: |
            - MIT
            - BSD-2-Clause
            - BSD-3-Clause
            - Apache-2.0
            - proprietary
```

The runner needs `composer`, `jq`, `git` and `curl`. With `use-locked: "true"` no `composer install` is required; the audit reads `composer.lock`.

## Inputs
- `composer-path` (default: `composer`): Path to the Composer executable. Useful when Composer is installed in a non-standard location.
- `use-locked` (default: `"false"`): When `true`, runs `composer licenses --locked` to read from `composer.lock` instead of installed packages. Use this for deterministic checks in CI.
- `allowed-licenses` (default not set): YAML-style multiline allowlist, one `- identifier` per line. When set, packages are marked ✅/❌ based on whether at least one of their licenses appears in the list (Composer treats multiple licenses on a package as alternatives you may choose from, so a `BSD-3-Clause OR GPL-2.0-only` package passes an allowlist containing `BSD-3-Clause`). Example:
  ```yaml
  allowed-licenses: |
    - MIT
    - Apache-2.0
    - BSD-3-Clause
  ```
  Entries are matched literally against the identifiers Composer reports. A package that declares its license as a single SPDX expression string (`"license": "(LGPL-2.1-only or GPL-3.0-or-later)"`, the only way Composer can express an `and` combination) is reported as that one string and is not parsed; it fails the allowlist unless the exact string is listed. This form is rare in practice.
  Packages without a license entry are reported as `UNKNOWN`; add `UNKNOWN` to the allowlist to accept them.
- `fail-hard` (default: `"true"`): When `true` and `allowed-licenses` is set, the action exits non-zero if any package has no license in the allowlist. Set to `"false"` to only report status without failing.
- `github-token` (default: `github.token`): Token used to create or update the pull request comment. Needs `pull-requests: write`.

## Output
- **Workflow log**: license counts and one line per package with its version, licenses and ✅/❌ marker.
- **Step summary**: the same data as Markdown tables (counts, all packages, and on pull requests the new packages), plus source (`installed packages` or `composer.lock (--locked)`), commit and the configured allowlist. The status column only appears when an allowlist is set. In the counts table a license is ❌ only when it causes a violation; a license outside the allowlist that only occurs next to an allowed one is marked ➖ and explained by a legend.
- **Exit code**: `1` when `fail-hard` is `true`, an allowlist is set and at least one package has no license in it; `0` otherwise.

## Pull request behavior
- On `pull_request` and `pull_request_target` events, the action reads `composer.lock` at the PR base commit and marks packages absent from it (in `packages` or `packages-dev`) as new. If the base commit is not in the checkout (shallow clone), the base branch is fetched with `--depth=1`.
- Override the base commit by setting the `PR_BASE_SHA` environment variable (handy for local testing or custom base refs). Without a resolvable base, new-package detection is skipped and the rest of the audit runs unchanged.
- The action posts one comment per pull request and updates it on later runs (it is found by a hidden `<!-- composer-license-audit:new-packages -->` marker). The comment lists the new packages with their licenses and allowlist status; when there are none it says so and lists all packages in a collapsed section. The comment is skipped, with a log message, when no token or PR number is available.
