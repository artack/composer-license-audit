#!/usr/bin/env bats
# Tests at the interface of src/audit.jq: fixtures in, one JSON result out.
# No composer, git, or network involved.

load test_helper

setup() {
  common_setup
  AUDIT="${REPO_ROOT}/src/audit.jq"
}

# audit <fixture-or-path> <allowlist-json> [base-lock-file]
audit() {
  local input="$1" allowlist="$2" base="${3:-/dev/null}"
  [[ "$input" == /* ]] || input="${FIXTURES}/${input}"
  run jq -c -f "$AUDIT" --argjson allowlist "$allowlist" --slurpfile base "$base" < "$input"
  assert_status 0
}

# field <jq-filter> -- evaluate against the last result, raw output.
field() {
  jq -rc "$1" <<<"$output"
}

assert_field() {
  local actual
  actual="$(field "$1")"
  [[ "$actual" == "$2" ]] || fail_with "expected $1 == '$2', got '$actual'"
}

@test "without allowlist or base, allowed and is_new are null and nothing is flagged" {
  audit mixed.json null
  assert_field '.allowlist_enabled' false
  assert_field '.base_available' false
  assert_field '.has_violations' false
  assert_field '[.packages[].allowed] | unique' '[null]'
  assert_field '[.packages[].is_new] | unique' '[null]'
  assert_field '[.counts[].allowed] | unique' '[null]'
}

@test "an empty allowlist array means the allowlist is disabled" {
  audit mixed.json '[]'
  assert_field '.allowlist_enabled' false
  assert_field '.has_violations' false
  assert_field '[.packages[].allowed] | unique' '[null]'
}

@test "allowed is true when at least one license of the package is in the allowlist" {
  audit mixed.json '["MIT","Apache-2.0"]'
  assert_field '.allowlist_enabled' true
  assert_field '.has_violations' true
  assert_field '.packages[] | select(.name == "vendor/mit-only") | .allowed' true
  assert_field '.packages[] | select(.name == "vendor/apache-only") | .allowed' true
  assert_field '.packages[] | select(.name == "vendor/dual-licensed") | .allowed' true
  assert_field '.packages[] | select(.name == "vendor/gpl-only") | .allowed' false
}

@test "a multi-licensed package is disallowed only when none of its licenses is in the allowlist" {
  audit mixed.json '["Apache-2.0"]'
  assert_field '.packages[] | select(.name == "vendor/dual-licensed") | .allowed' false
  audit mixed.json '["GPL-2.0-or-later"]'
  assert_field '.packages[] | select(.name == "vendor/dual-licensed") | .allowed' true
}

@test "UNKNOWN is a license like any other: disallowed unless listed" {
  audit mixed.json '["MIT","Apache-2.0"]'
  assert_field '.packages[] | select(.name == "vendor/null-license") | .allowed' false
  audit mixed.json '["MIT","Apache-2.0","GPL-2.0-or-later","GPL-3.0-only","UNKNOWN"]'
  assert_field '.packages[] | select(.name == "vendor/null-license") | .allowed' true
  assert_field '.has_violations' false
}

@test "normalizes null, [] and a bare string license; missing version becomes unknown" {
  printf '%s' '{"dependencies":{"a/string":{"license":"MIT"},"a/null":{"version":"1.0","license":null},"a/empty":{"version":"2.0","license":[]}}}' > input.json
  audit "$PWD/input.json" null
  assert_field '.packages[] | select(.name == "a/string") | .licenses' '["MIT"]'
  assert_field '.packages[] | select(.name == "a/string") | .version' unknown
  assert_field '.packages[] | select(.name == "a/null") | .licenses' '["UNKNOWN"]'
  assert_field '.packages[] | select(.name == "a/empty") | .licenses' '["UNKNOWN"]'
}

@test "packages sort by name; counts sort by count desc then license" {
  audit mixed.json null
  assert_field '[.packages[].name] | join(",")' 'vendor/apache-only,vendor/dual-licensed,vendor/gpl-only,vendor/mit-only,vendor/no-license,vendor/null-license'
  assert_field '[.counts[] | "\(.license)=\(.count)"] | join(",")' 'MIT=2,UNKNOWN=2,Apache-2.0=1,GPL-2.0-or-later=1,GPL-3.0-only=1'
}

@test "counts carry the allowlist verdict of their license" {
  audit mixed.json '["MIT","Apache-2.0"]'
  assert_field '.counts[] | select(.license == "MIT") | .allowed' true
  assert_field '.counts[] | select(.license == "GPL-3.0-only") | .allowed' false
}

@test "is_new marks packages absent from the base composer.lock" {
  audit pr-head.json null "${FIXTURES}/base-composer.lock"
  assert_field '.base_available' true
  assert_field '.packages[] | select(.name == "psr/log") | .is_new' false
  assert_field '.packages[] | select(.name == "nikic/php-parser") | .is_new' true
}

@test "a base lock without packages counts as no base" {
  printf '%s' '{"packages":[],"packages-dev":[]}' > empty-base.lock
  audit pr-head.json null "$PWD/empty-base.lock"
  assert_field '.base_available' false
  assert_field '[.packages[].is_new] | unique' '[null]'
}

@test "packages-dev in the base lock count as known" {
  printf '%s' '{"packages":[],"packages-dev":[{"name":"nikic/php-parser","version":"v4.19.5"}]}' > dev-base.lock
  audit pr-head.json null "$PWD/dev-base.lock"
  assert_field '.packages[] | select(.name == "nikic/php-parser") | .is_new' false
  assert_field '.packages[] | select(.name == "psr/log") | .is_new' true
}

@test "a project without dependencies yields empty lists and no violations" {
  audit empty.json '["MIT"]'
  assert_field '.packages | length' 0
  assert_field '.counts | length' 0
  assert_field '.has_violations' false
}
