# Repository Guidelines

## Project Structure & Module Organization
- Root contains `action.yml` (composite action entry), `README.md`, and this guide.
- `src/license-summary.sh`: Bash script that runs `composer licenses` and formats the summary.
- `.github/workflows/test.yml`: Self-test workflow creating a dummy Composer project and exercising the action with and without `--locked`.

## Build, Test, and Development Commands
- Run the test workflow locally with Act (requires Docker): `act -j license-audit --container-architecture linux/amd64 -P ubuntu-latest=shivammathur/node:latest`.
- Execute the license script directly (from repo root): `src/license-summary.sh composer false` or `src/license-summary.sh composer true` (second arg toggles `--locked`).
- Compose action invocation (example step):  
  ```yaml
  - uses: ./
    with:
      composer-path: composer
      use-locked: "true"
      allowed-licenses: "MIT,Apache-2.0"
  ```

## Coding Style & Naming Conventions
- Bash scripts: `set -euo pipefail`, prefer arrays for command construction, keep functions small; use tab-separated processing only where necessary.
- YAML: two-space indentation; keep step names explicit and concise.
- File naming: hyphen-separated for scripts (e.g., `license-summary.sh`); workflows in `.github/workflows` with descriptive filenames.

## Testing Guidelines
- Primary check is the Act run above (same command as in Build section); ensure output matches expected license counts and alignment.
- When changing `src/license-summary.sh`, test both modes (installed and `--locked`) and at least one package with multiple license entries to confirm grouping.
- If supplying `allowed-licenses`, confirm ✅/❌ markers correctly flag packages outside the allowlist.
- Keep dummy dependencies minimal to reduce runtime; avoid network-heavy additions.

## Commit & Pull Request Guidelines
- Commits: use clear, imperative messages (e.g., “Add act test workflow”, “Handle locked license mode”).
- PRs: include summary of changes, testing performed (include Act command/output), and any impact on inputs or defaults. Link related issues when available.
- Screenshots are unnecessary; paste relevant log excerpts if adjusting output formatting.

## Security & Configuration Tips
- Avoid embedding secrets; the action only needs Composer and jq in the environment.
- Keep Composer invocations non-interactive; prefer `--no-interaction` in examples.
- For Apple Silicon users running Act, set `--container-architecture linux/amd64` to avoid platform mismatches.
