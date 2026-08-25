#!/usr/bin/env bats
# Pull-request behaviour: base comparison and the GitHub comment create/update path,
# exercised against tests/fixtures/github-api-stub.py.

load test_helper

setup() {
  common_setup
  setup_pr_base base-composer.lock
  export GITHUB_TOKEN=test-token
  export GITHUB_EVENT_NUMBER=7
}

teardown() {
  stop_github_stub
}

COMMENTS_PATH="/repos/example/repo/issues/7/comments"
MARKER="<!-- composer-license-audit:new-packages -->"

# --- base comparison ---------------------------------------------------------

@test "detects packages missing from the base composer.lock" {
  use_fixture pr-head.json
  start_github_stub
  run_audit false $'- MIT\n- BSD-3-Clause'
  assert_status 0
  assert_output_contains "Base packages loaded: yes (sha=${PR_BASE_SHA}); new packages detected: 1"
  assert_summary_contains "#### New packages"
  assert_summary_contains "| nikic/php-parser | v4.19.5 | BSD-3-Clause | ✅ |"
  # psr/log is in the base; it must only appear in the full package list, not under "New packages".
  local new_section
  new_section="$(sed -n '/#### New packages/,$p' "$GITHUB_STEP_SUMMARY")"
  ! grep -q "psr/log" <<<"$new_section" || fail_with "psr/log listed as new"
}

@test "reads the base sha from the event payload when PR_BASE_SHA is unset" {
  use_fixture pr-head.json
  start_github_stub
  printf '{"pull_request":{"base":{"sha":"%s"}}}' "$PR_BASE_SHA" > event.json
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$PWD/event.json"
  unset PR_BASE_SHA
  run_audit
  assert_output_contains "Base packages loaded: yes"
  assert_output_contains "new packages detected: 1"
}

@test "ignores an unknown base sha" {
  use_fixture pr-head.json
  start_github_stub
  export PR_BASE_SHA=0000000000000000000000000000000000000000
  run_audit
  assert_status 0
  assert_output_contains "Base packages loaded: no; new packages detection skipped"
  assert_summary_lacks "#### New packages"
}

# --- comment creation --------------------------------------------------------

@test "creates a comment listing new packages when none exists" {
  use_fixture pr-head.json
  start_github_stub
  run_audit false $'- MIT\n- BSD-3-Clause'
  assert_status 0
  assert_output_contains "Created pull request license summary comment."

  [[ "$(stub_request_count '.method == "GET"')" -eq 1 ]] || fail_with "expected one comment lookup: $(stub_requests)"
  [[ "$(stub_request_count ".method == \"POST\" and .path == \"${COMMENTS_PATH}\"")" -eq 1 ]] || fail_with "expected one POST: $(stub_requests)"
  [[ "$(stub_request_count '.method == "PATCH"')" -eq 0 ]] || fail_with "unexpected PATCH: $(stub_requests)"

  local body
  body="$(stub_comment_body '.method == "POST"')"
  grep -qF "$MARKER" <<<"$body" || fail_with "comment lacks marker: $body"
  grep -qF "#### New packages" <<<"$body" || fail_with "comment lacks new packages heading: $body"
  grep -qF "| nikic/php-parser | v4.19.5 | BSD-3-Clause | ✅ |" <<<"$body" || fail_with "comment lacks new package row: $body"
  grep -qF "<summary>All packages</summary>" <<<"$body" || fail_with "comment lacks full package list: $body"
  grep -qF "| psr/log | 3.0.2 | MIT | ✅ |" <<<"$body" || fail_with "comment lacks existing package row: $body"
  grep -qE 'Last checked at `[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC`' <<<"$body" || fail_with "comment lacks timestamp: $body"
}

@test "sends the token as a bearer header" {
  use_fixture pr-head.json
  start_github_stub
  run_audit
  [[ "$(stub_requests | jq -rs 'map(.headers.authorization) | unique | .[]')" == "Bearer test-token" ]] \
    || fail_with "unexpected authorization headers: $(stub_requests | jq -c '.headers.authorization')"
}

@test "omits the status column from the comment without an allowlist" {
  use_fixture pr-head.json
  start_github_stub
  run_audit
  local body
  body="$(stub_comment_body '.method == "POST"')"
  grep -qF "| Package | Version | Licenses |" <<<"$body" || fail_with "comment lacks table header: $body"
  ! grep -qF "| Status |" <<<"$body" || fail_with "comment unexpectedly has a status column: $body"
  ! grep -qF "✅" <<<"$body" || fail_with "comment unexpectedly has status icons: $body"
}

@test "still posts the comment, with ❌, when a new package fails the allowlist" {
  use_fixture pr-head.json
  start_github_stub
  run_audit false "- MIT" true
  assert_status 1
  assert_output_contains "Created pull request license summary comment."
  local body
  body="$(stub_comment_body '.method == "POST"')"
  grep -qF "| nikic/php-parser | v4.19.5 | BSD-3-Clause | ❌ |" <<<"$body" || fail_with "new package not marked ❌: $body"
}

@test "posts an informational comment when there are no new packages" {
  use_fixture pr-base-only.json
  start_github_stub
  run_audit
  assert_status 0
  assert_output_contains "No new packages found; posting informational PR comment."
  assert_output_contains "Created pull request license summary comment noting no new packages."
  assert_summary_contains "No new packages compared to the PR base."
  local body
  body="$(stub_comment_body '.method == "POST"')"
  grep -qF "$MARKER" <<<"$body" || fail_with "comment lacks marker: $body"
  grep -qF "No new packages detected in this pull request." <<<"$body" || fail_with "comment lacks no-new-packages text: $body"
  grep -qF "| psr/log | 3.0.2 | MIT |" <<<"$body" || fail_with "comment lacks package list: $body"
}

# --- comment update ----------------------------------------------------------

@test "updates the existing marker comment instead of creating a new one" {
  use_fixture pr-head.json
  jq -n --arg marker "$MARKER" --arg path "${COMMENTS_PATH}?per_page=100&page=1" \
    '{($path): [{id: 41, body: "unrelated comment"}, {id: 42, body: ($marker + "\nold summary")}]}' > responses.json
  start_github_stub responses.json
  run_audit
  assert_status 0
  assert_output_contains "Updated pull request license summary comment (42)."
  [[ "$(stub_request_count '.method == "POST"')" -eq 0 ]] || fail_with "unexpected POST: $(stub_requests)"
  [[ "$(stub_request_count '.method == "PATCH" and .path == "/repos/example/repo/issues/comments/42"')" -eq 1 ]] \
    || fail_with "expected PATCH of comment 42: $(stub_requests)"
  local body
  body="$(stub_comment_body '.method == "PATCH"')"
  grep -qF "| nikic/php-parser | v4.19.5 | BSD-3-Clause |" <<<"$body" || fail_with "updated comment lacks new package: $body"
}

@test "updates the existing comment in the no-new-packages case too" {
  use_fixture pr-base-only.json
  jq -n --arg marker "$MARKER" --arg path "${COMMENTS_PATH}?per_page=100&page=1" \
    '{($path): [{id: 42, body: ($marker + "\nold summary")}]}' > responses.json
  start_github_stub responses.json
  run_audit
  assert_output_contains "Updated pull request license summary comment (42) to note no new packages."
  [[ "$(stub_request_count '.method == "PATCH"')" -eq 1 ]] || fail_with "expected one PATCH: $(stub_requests)"
}

@test "pages through comments to find the marker" {
  use_fixture pr-head.json
  jq -n --arg marker "$MARKER" \
    --arg p1 "${COMMENTS_PATH}?per_page=100&page=1" \
    --arg p2 "${COMMENTS_PATH}?per_page=100&page=2" \
    '{($p1): [range(100) | {id: ., body: "noise \(.)"}], ($p2): [{id: 500, body: ($marker + "\nold")}]}' > responses.json
  start_github_stub responses.json
  run_audit
  assert_output_contains "Updated pull request license summary comment (500)."
  [[ "$(stub_request_count '.method == "GET"')" -eq 2 ]] || fail_with "expected two GET pages: $(stub_requests | jq -c '[.method,.path]')"
}

@test "stops paging when a page has fewer than 100 comments" {
  use_fixture pr-head.json
  jq -n --arg path "${COMMENTS_PATH}?per_page=100&page=1" \
    '{($path): [range(3) | {id: ., body: "noise"}]}' > responses.json
  start_github_stub responses.json
  run_audit
  assert_output_contains "Created pull request license summary comment."
  [[ "$(stub_request_count '.method == "GET"')" -eq 1 ]] || fail_with "expected a single GET: $(stub_requests | jq -c '[.method,.path]')"
}

# --- skipped cases -----------------------------------------------------------

@test "skips the comment when GITHUB_TOKEN is empty" {
  use_fixture pr-head.json
  start_github_stub
  export GITHUB_TOKEN=""
  run_audit
  assert_status 0
  assert_output_contains "Skipping PR comment: GITHUB_TOKEN not set or empty."
  [[ -z "$(stub_requests)" ]] || fail_with "unexpected API traffic: $(stub_requests)"
}

@test "skips the comment when the PR number is unavailable" {
  use_fixture pr-head.json
  start_github_stub
  unset GITHUB_EVENT_NUMBER
  run_audit
  assert_status 0
  assert_output_contains "Skipping PR comment: pull request number not available."
  [[ -z "$(stub_requests)" ]] || fail_with "unexpected API traffic: $(stub_requests)"
}
