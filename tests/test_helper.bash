# shellcheck shell=bash
# Shared helpers for the Bats suites. Loaded via `load test_helper`.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/src/license-summary.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures"
export REPO_ROOT SCRIPT FIXTURES

# Put the composer shim first on PATH and start every test from a clean GitHub-like environment.
common_setup() {
  PATH="${FIXTURES}/bin:${PATH}"
  export PATH
  export STUB_COMPOSER_ARGS_FILE="${BATS_TEST_TMPDIR}/composer-args"
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  export GITHUB_EVENT_NAME=push
  export GITHUB_REPOSITORY=example/repo
  # Never let the developer's shell leak these into a test.
  unset GITHUB_TOKEN GITHUB_EVENT_NUMBER GITHUB_EVENT_PATH GITHUB_BASE_REF PR_BASE_SHA GITHUB_API_URL
  cd "$BATS_TEST_TMPDIR" || return 1
}

use_fixture() {
  export STUB_COMPOSER_JSON="${FIXTURES}/$1"
}

# run_audit [use_locked] [allowed] [fail_hard] -- runs the script through the PATH shim.
run_audit() {
  run "$SCRIPT" composer "${1:-false}" "${2:-}" "${3:-true}"
}

summary() {
  cat "$GITHUB_STEP_SUMMARY"
}

composer_args() {
  cat "$STUB_COMPOSER_ARGS_FILE" 2>/dev/null || true
}

# --- assertions -------------------------------------------------------------

fail_with() {
  {
    echo "$1"
    echo "--- status: ${status:-?} ---"
    echo "--- output ---"
    echo "${output:-}"
    echo "--- summary ---"
    summary 2>/dev/null || true
  } >&2
  return 1
}

assert_status() {
  [[ "$status" -eq "$1" ]] || fail_with "expected exit status $1, got $status"
}

assert_output_contains() {
  grep -qF -- "$1" <<<"$output" || fail_with "expected output to contain: $1"
}

assert_output_lacks() {
  ! grep -qF -- "$1" <<<"$output" || fail_with "expected output NOT to contain: $1"
}

assert_summary_contains() {
  grep -qF -- "$1" < "$GITHUB_STEP_SUMMARY" || fail_with "expected step summary to contain: $1"
}

assert_summary_lacks() {
  ! grep -qF -- "$1" < "$GITHUB_STEP_SUMMARY" || fail_with "expected step summary NOT to contain: $1"
}

assert_summary_empty() {
  [[ ! -s "$GITHUB_STEP_SUMMARY" ]] || fail_with "expected step summary to be empty"
}

# --- PR base repository -----------------------------------------------------

# Create a git repo in the cwd whose HEAD holds the given composer.lock fixture; exports PR_BASE_SHA.
setup_pr_base() {
  git init -q .
  cp "${FIXTURES}/$1" composer.lock
  git add composer.lock
  git -c user.email=test@example.com -c user.name=Test commit -qm "Base dependencies"
  PR_BASE_SHA="$(git rev-parse HEAD)"
  export PR_BASE_SHA
}

# --- GitHub API stub --------------------------------------------------------

# start_github_stub [responses.json] -- starts the stub and points GITHUB_API_URL at it.
start_github_stub() {
  STUB_DIR="${BATS_TEST_TMPDIR}/github-stub"
  mkdir -p "$STUB_DIR"
  [[ -n "${1:-}" ]] && cp "$1" "${STUB_DIR}/responses.json"
  # fd 3 must be closed for background processes or bats waits on them forever.
  python3 "${FIXTURES}/github-api-stub.py" "$STUB_DIR" 3>&- &
  STUB_PID=$!

  for _ in $(seq 1 50); do
    [[ -s "${STUB_DIR}/port" ]] && break
    sleep 0.1
  done
  [[ -s "${STUB_DIR}/port" ]] || { echo "GitHub API stub did not start" >&2; return 1; }
  GITHUB_API_URL="http://127.0.0.1:$(cat "${STUB_DIR}/port")"
  export GITHUB_API_URL STUB_DIR STUB_PID
}

stop_github_stub() {
  if [[ -n "${STUB_PID:-}" ]]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
}

# All recorded requests, one JSON object per line.
stub_requests() {
  cat "${STUB_DIR}/requests.jsonl" 2>/dev/null || true
}

# stub_request_count [jq-filter] -- number of recorded requests matching the filter.
stub_request_count() {
  stub_requests | jq -s "map(select(${1:-true})) | length"
}

# stub_request_body <jq-filter> -- the .body.body (comment text) of the first matching request.
stub_comment_body() {
  stub_requests | jq -rs "map(select($1)) | first | .body.body"
}
