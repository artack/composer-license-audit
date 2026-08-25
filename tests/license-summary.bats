#!/usr/bin/env bats
# Output, grouping, allowlist and fail-hard behaviour of src/license-summary.sh.

load test_helper

setup() {
  common_setup
}

ALLOWED=$'- MIT\n- Apache-2.0'

# --- no allowlist -------------------------------------------------------------

@test "exits 0 and prints counts without an allowlist" {
  use_fixture mixed.json
  run_audit
  assert_status 0
  assert_output_contains "License counts:"
  assert_output_lacks "❌"
  assert_output_lacks "✅"
}

@test "counts a license once per package, across multi-license packages" {
  use_fixture mixed.json
  run_audit
  # MIT: mit-only + dual-licensed; GPL-2.0-or-later: dual-licensed only
  assert_output_contains "$(printf '%-20s %s' MIT 2)"
  assert_output_contains "$(printf '%-20s %s' GPL-2.0-or-later 1)"
  assert_summary_contains "| MIT | 2 |"
}

@test "normalizes [] and null licenses to UNKNOWN" {
  use_fixture mixed.json
  run_audit
  assert_output_contains "$(printf '%-20s %s' UNKNOWN 2)"
  assert_summary_contains "| vendor/null-license | v0.1.0 | UNKNOWN |"
  assert_summary_contains "| vendor/no-license | v0.9.0 | UNKNOWN |"
}

@test "joins multiple licenses of one package with a comma" {
  use_fixture mixed.json
  run_audit
  assert_output_contains "vendor/dual-licensed           v3.1.0          MIT, GPL-2.0-or-later"
  assert_summary_contains "| vendor/dual-licensed | v3.1.0 | MIT, GPL-2.0-or-later |"
}

@test "summary tables have no status column without an allowlist" {
  use_fixture mixed.json
  run_audit
  assert_summary_contains "| License | Count |"
  assert_summary_contains "| Package | Version | Licenses |"
  assert_summary_lacks "| Status |"
}

@test "skips base comparison outside pull requests" {
  use_fixture mixed.json
  run_audit
  assert_output_contains "Base packages loaded: no; new packages detection skipped"
  assert_summary_lacks "#### New packages"
}

# --- composer invocation -----------------------------------------------------

@test "passes --locked to composer when use-locked is true" {
  use_fixture mixed.json
  run_audit true
  assert_status 0
  [[ "$(composer_args)" == *"--locked"* ]] || fail_with "composer was not called with --locked: $(composer_args)"
  assert_summary_contains 'composer.lock (--locked)'
}

@test "omits --locked when use-locked is false" {
  use_fixture mixed.json
  run_audit false
  [[ "$(composer_args)" != *"--locked"* ]] || fail_with "composer was unexpectedly called with --locked"
  assert_summary_contains 'installed packages'
}

# --- allowlist ---------------------------------------------------------------

@test "fails with exit 1 when a license is outside the allowlist" {
  use_fixture mixed.json
  run_audit false "$ALLOWED" true
  assert_status 1
  assert_output_contains "Found disallowed licenses not in the allowed list."
}

@test "marks packages ✅/❌ against the allowlist" {
  use_fixture mixed.json
  run_audit false "$ALLOWED" true
  assert_output_contains "vendor/mit-only                v1.2.3          ✅ MIT"
  assert_output_contains "vendor/apache-only             v2.0.0          ✅ Apache-2.0"
  assert_output_contains "vendor/gpl-only                v4.0.0          ❌ GPL-3.0-only"
}

@test "marks a package ❌ when only one of its licenses is disallowed" {
  use_fixture mixed.json
  run_audit false "$ALLOWED" true
  assert_output_contains "vendor/dual-licensed           v3.1.0          ❌ MIT, GPL-2.0-or-later"
}

@test "treats UNKNOWN as disallowed unless explicitly allowed" {
  use_fixture mixed.json
  run_audit false "$ALLOWED" true
  assert_output_contains "vendor/null-license            v0.1.0          ❌ UNKNOWN"
  run_audit false $'- MIT\n- UNKNOWN' false
  assert_output_contains "vendor/null-license            v0.1.0          ✅ UNKNOWN"
}

@test "summary tables carry a status column with an allowlist" {
  use_fixture mixed.json
  run_audit false "$ALLOWED" true
  assert_summary_contains "| License | Count | Status |"
  assert_summary_contains "| MIT | 2 | ✅ |"
  assert_summary_contains "| GPL-3.0-only | 1 | ❌ |"
  assert_summary_contains "| vendor/gpl-only | v4.0.0 | GPL-3.0-only | ❌ |"
}

@test "summary lists the allowlist sorted and comma-separated" {
  use_fixture mixed.json
  run_audit false $'- MIT\n- Apache-2.0\n- BSD-3-Clause' false
  assert_summary_contains '- Allowed licenses: `Apache-2.0`, `BSD-3-Clause`, `MIT`'
}

@test "exits 0 when every license is allowed" {
  use_fixture mixed.json
  run_audit false $'- MIT\n- Apache-2.0\n- GPL-2.0-or-later\n- GPL-3.0-only\n- UNKNOWN' true
  assert_status 0
  assert_output_lacks "❌"
}

@test "tolerates whitespace and blank lines in the allowlist" {
  use_fixture mixed.json
  run_audit false $'  -   MIT  \n\n- Apache-2.0\n' true
  assert_output_contains "vendor/mit-only                v1.2.3          ✅ MIT"
}

@test "does not accept a comma-separated allowlist (documents current behaviour)" {
  use_fixture mixed.json
  run_audit false "MIT,Apache-2.0" true
  assert_output_contains "vendor/mit-only                v1.2.3          ❌ MIT"
}

# --- fail-hard ---------------------------------------------------------------

@test "fail-hard=false reports violations but exits 0" {
  use_fixture mixed.json
  run_audit false "$ALLOWED" false
  assert_status 0
  assert_output_contains "❌"
  assert_output_lacks "Found disallowed licenses"
}

@test "fail-hard is case-insensitive" {
  use_fixture mixed.json
  run_audit false "$ALLOWED" FALSE
  assert_status 0
  run_audit false "$ALLOWED" True
  assert_status 1
}

@test "fail-hard has no effect without an allowlist" {
  use_fixture mixed.json
  run_audit false "" true
  assert_status 0
}

# --- empty project -----------------------------------------------------------

@test "exits 0 and writes no summary for a project without dependencies" {
  use_fixture empty.json
  run_audit false "$ALLOWED" true
  assert_status 0
  assert_output_contains "No dependency licenses found."
  assert_summary_empty
}
