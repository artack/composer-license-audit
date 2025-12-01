#!/usr/bin/env bash
set -euo pipefail

composer_path="${1:-composer}"
use_locked="${2:-false}"
allowed_raw="${3:-}"
fail_hard="${4:-true}"
ACTION_VERSION="0.0.2"
GITHUB_SHA="${GITHUB_SHA:-}"

[[ -z "$GITHUB_SHA" ]] && GITHUB_SHA="unknown"

cmd=("$composer_path" licenses --format=json)
if [[ "${use_locked}" == "true" ]]; then
  cmd+=("--locked")
fi

echo "Running: ${cmd[*]}"
json_output="$("${cmd[@]}")"

echo "Action version: ${ACTION_VERSION}"
echo "GITHUB_EVENT_NAME=${GITHUB_EVENT_NAME:-}"
echo "GITHUB_EVENT_PATH=${GITHUB_EVENT_PATH:-}"
echo "GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-}"
echo "GITHUB_REF=${GITHUB_REF:-}"
echo "GITHUB_REF_NAME=${GITHUB_REF_NAME:-}"
echo "GITHUB_HEAD_REF=${GITHUB_HEAD_REF:-}"
echo "GITHUB_EVENT_NUMBER=${GITHUB_EVENT_NUMBER:-}"
echo "GITHUB_ACTION_REPOSITORY=${GITHUB_ACTION_REPOSITORY:-}"
echo "GITHUB_ACTION_REF=${GITHUB_ACTION_REF:-}"
echo "License audit commit SHA: ${GITHUB_SHA}"

if [[ "${GITHUB_EVENT_NAME:-}" == "push" ]]; then
  echo "Detected GitHub event: push"
elif [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" || "${GITHUB_EVENT_NAME:-}" == "pull_request_target" ]]; then
  echo "Detected GitHub event: pull request"
else
  echo "Detected GitHub event: ${GITHUB_EVENT_NAME:-unknown}"
fi
if [[ -n "${GITHUB_ACTION_REPOSITORY:-}" || -n "${GITHUB_ACTION_REF:-}" ]]; then
  echo "Action info: repo=${GITHUB_ACTION_REPOSITORY:-unknown} ref=${GITHUB_ACTION_REF:-unknown}"
fi

base_debug="Base packages loaded: no"
license_counts_tsv=$(printf '%s\n' "$json_output" | jq -r '
  def normalize_license($licenses):
    if $licenses == null then ["UNKNOWN"]
    elif ($licenses | type) == "array" then (if ($licenses | length) == 0 then ["UNKNOWN"] else $licenses end)
    else [$licenses]
    end;

  (.dependencies // {})
  | to_entries
  | map(normalize_license(.value.license))
  | flatten
  | sort
  | group_by(.)
  | map({license: .[0], count: length})
  | sort_by(-.count, .license)
  | .[]
  | "\(.license)\t\(.count)"
')

package_details_tsv=$(printf '%s\n' "$json_output" | jq -r '
  def normalize_license($licenses):
    if $licenses == null then ["UNKNOWN"]
    elif ($licenses | type) == "array" then (if ($licenses | length) == 0 then ["UNKNOWN"] else $licenses end)
    else [$licenses]
    end;

  (.dependencies // {})
  | to_entries
  | map({
      name: .key,
      version: (.value.version // "unknown"),
      licenses: (normalize_license(.value.license) | join(", "))
    })
  | sort_by(.name)
  | .[]
  | "\(.name)\t\(.version)\t\(.licenses)"
')

if [[ -z "$license_counts_tsv" ]]; then
  echo "No dependency licenses found."
  exit 0
fi

declare -A allowed_set=()
allowed_check_enabled=0
if [[ -n "$allowed_raw" ]]; then
  while IFS= read -r part; do
    # Expect YAML-style list entries: "- MIT"
    trimmed="$(echo "$part" | sed 's/^[[:space:]]*-[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$trimmed" ]] && allowed_set["$trimmed"]=1
  done <<< "$allowed_raw"
  if (( ${#allowed_set[@]} > 0 )); then
    allowed_check_enabled=1
  fi
fi
fail_hard_enabled=0
fail_hard_normalized="$(echo "$fail_hard" | tr '[:upper:]' '[:lower:]')"
if [[ "$fail_hard_normalized" == "true" ]]; then
  fail_hard_enabled=1
fi
violations_found=0

# Load base composer.lock package names for PR comparisons
# Load base composer.lock package names for PR comparisons
declare -A base_packages=()
base_packages_available=0
base_sha_override="${PR_BASE_SHA:-}"
if [[ -z "$base_sha_override" ]]; then
  if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" || "${GITHUB_EVENT_NAME:-}" == "pull_request_target" ]]; then
    if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH:-}" ]]; then
      base_sha_override="$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
    fi
  fi
fi

if [[ -n "$base_sha_override" ]] && ! git cat-file -e "${base_sha_override}^{commit}" 2>/dev/null; then
  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    echo "Base commit ${base_sha_override} not present; fetching base ref ${GITHUB_BASE_REF}."
    git fetch --no-tags --depth=1 origin "refs/heads/${GITHUB_BASE_REF}:refs/remotes/origin/${GITHUB_BASE_REF}" || true
    if git cat-file -e "refs/remotes/origin/${GITHUB_BASE_REF}^{commit}" 2>/dev/null; then
      base_sha_override="$(git rev-parse "refs/remotes/origin/${GITHUB_BASE_REF}")"
      echo "Using fetched base sha ${base_sha_override}."
    fi
  fi
fi

if [[ -n "$base_sha_override" ]] && git cat-file -e "${base_sha_override}^{commit}" 2>/dev/null; then
  base_lock_json="$(git show "${base_sha_override}:composer.lock" 2>/dev/null || true)"
  if [[ -n "$base_lock_json" ]]; then
    base_packages_list="$(printf '%s\n' "$base_lock_json" | jq -r '
      [
        (.packages // [] | .[].name),
        (.["packages-dev"] // [] | .[].name)
      ]
      | flatten
      | .[]
    ' 2>/dev/null || true)"
    if [[ -n "$base_packages_list" ]]; then
      while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        base_packages["$pkg"]=1
      done <<< "$base_packages_list"
      if (( ${#base_packages[@]} > 0 )); then
        base_packages_available=1
        base_debug="Base packages loaded: yes (sha=${base_sha_override})"
      fi
    fi
  fi
fi

license_status_icon() {
  local licenses="$1"
  local status_icon="✅"

  IFS=',' read -ra license_arr <<< "$licenses"
  for lic in "${license_arr[@]}"; do
    local lic_trimmed
    lic_trimmed="$(echo "$lic" | xargs)"
    [[ -z "$lic_trimmed" ]] && continue
    if [[ -z "${allowed_set[$lic_trimmed]:-}" ]]; then
      status_icon="❌"
      break
    fi
  done

  echo "$status_icon"
}

formatted_counts=$(printf '%s\n' "$license_counts_tsv" | awk -F '\t' '{printf "%-20s %s\n", $1, $2}')

echo "License counts:"
printf '%s\n' "$formatted_counts"

new_packages=()
if (( base_packages_available )) && [[ -n "$package_details_tsv" ]]; then
  while IFS=$'\t' read -r name version licenses; do
    [[ -z "$name" ]] && continue
    if [[ -z "${base_packages[$name]:-}" ]]; then
      new_packages+=("$name"$'\t'"$version"$'\t'"$licenses")
    fi
  done <<< "$package_details_tsv"
  new_pkg_count=${#new_packages[@]}
  echo "$base_debug; new packages detected: ${new_pkg_count}"
else
  echo "$base_debug; new packages detection skipped"
fi

if [[ -n "$package_details_tsv" ]]; then
  echo
  echo "Package licenses:"
  while IFS=$'\t' read -r name version licenses; do
    if (( allowed_check_enabled )); then
      status_icon="$(license_status_icon "$licenses")"
      if [[ "$status_icon" == "❌" ]]; then
        violations_found=1
      fi
      printf '%-30s %-15s %-3s %s\n' "$name" "$version" "$status_icon" "$licenses"
    else
      printf '%-30s %-15s %s\n' "$name" "$version" "$licenses"
    fi
  done <<< "$package_details_tsv"

  if (( base_packages_available )); then
    echo
    echo "New packages vs base:"
    if (( ${#new_packages[@]} > 0 )); then
      for row in "${new_packages[@]}"; do
        IFS=$'\t' read -r name version licenses <<<"$row"
        [[ -z "$name" ]] && continue
        if (( allowed_check_enabled )); then
          status_icon="$(license_status_icon "$licenses")"
          if [[ "$status_icon" == "❌" ]]; then
            violations_found=1
          fi
          printf '%-30s %-15s %-3s %s\n' "$name" "$version" "$status_icon" "$licenses"
        else
          printf '%-30s %-15s %s\n' "$name" "$version" "$licenses"
        fi
      done
    else
      echo "None."
    fi
  fi
fi

# Append to GitHub job summary when available
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  source_label=$([[ "${use_locked}" == "true" ]] && echo "composer.lock (--locked)" || echo "installed packages")
  {
    echo "### Composer License Audit"
    echo "#### Summary"
    echo "- Source: \`${source_label}\`"
    echo "- Commit: \`${GITHUB_SHA}\`"
    if (( allowed_check_enabled )); then
      allowed_sorted="$(printf '%s\n' "${!allowed_set[@]}" | sort)"
      allowed_display="$(printf '%s\n' "$allowed_sorted" | sed 's/^/`/;s/$/`/' | paste -sd ', ' -)"
      echo "- Allowed licenses: ${allowed_display}"
    fi
    echo
    if (( allowed_check_enabled )); then
      echo "| License | Count | Status |"
      echo "| --- | --- | --- |"
      printf '%s\n' "$license_counts_tsv" | while IFS=$'\t' read -r license count; do
        status_icon="$(license_status_icon "$license")"
        if [[ "$status_icon" == "❌" ]]; then
          violations_found=1
        fi
        echo "| ${license} | ${count} | ${status_icon} |"
      done
    else
      echo "| License | Count |"
      echo "| --- | --- |"
      printf '%s\n' "$license_counts_tsv" | while IFS=$'\t' read -r license count; do
        echo "| ${license} | ${count} |"
      done
    fi
    if [[ -n "$package_details_tsv" ]]; then
      echo
      echo "<details>"
      echo "<summary>Package Licenses</summary>"
      echo
      if (( allowed_check_enabled )); then
        echo "| Package | Version | Licenses | Status |"
        echo "| --- | --- | --- | --- |"
        printf '%s\n' "$package_details_tsv" | while IFS=$'\t' read -r name version licenses; do
          status_icon="$(license_status_icon "$licenses")"
          if [[ "$status_icon" == "❌" ]]; then
            violations_found=1
          fi
          echo "| ${name} | ${version} | ${licenses} | ${status_icon} |"
        done
      else
        echo "| Package | Version | Licenses |"
        echo "| --- | --- | --- |"
        printf '%s\n' "$package_details_tsv" | while IFS=$'\t' read -r name version licenses; do
          echo "| ${name} | ${version} | ${licenses} |"
        done
      fi
      echo
      echo "</details>"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && (( base_packages_available )); then
  {
    echo
    echo "#### New packages"
    if (( ${#new_packages[@]} > 0 )); then
      if (( allowed_check_enabled )); then
        echo "| Package | Version | Licenses | Status |"
        echo "| --- | --- | --- | --- |"
        for row in "${new_packages[@]}"; do
          IFS=$'\t' read -r name version licenses <<<"$row"
          status_icon="$(license_status_icon "$licenses")"
          if [[ "$status_icon" == "❌" ]]; then
            violations_found=1
          fi
          echo "| ${name} | ${version} | ${licenses} | ${status_icon} |"
        done
      else
        echo "| Package | Version | Licenses |"
        echo "| --- | --- | --- |"
        for row in "${new_packages[@]}"; do
          IFS=$'\t' read -r name version licenses <<<"$row"
          echo "| ${name} | ${version} | ${licenses} |"
        done
      fi
    else
      echo "No new packages compared to the PR base."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

pr_number="${GITHUB_EVENT_NUMBER:-}"
echo "PR number (issue.number): ${pr_number:-<empty>}"

find_existing_comment_id() {
  local api_url="$1"
  local pr_number="$2"
  local marker="$3"
  local page=1
  local response=""
  local response_length=0
  local id=""

  echo "Debug find_existing_comment_id inputs: api_url=${api_url} repository=${GITHUB_REPOSITORY} pr_number=${pr_number} marker=${marker}" >&2

  while (( page <= 10 )); do
    echo "Fetching existing comments for PR ${pr_number}, page ${page}..." >&2
    # https://api.github.com/repos/artack/agrola_llp/issues/15/comments
    response="$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
      "${api_url}/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments?per_page=100&page=${page}" 2>/dev/null || true)"
    response_length=${#response}
    echo "Debug find_existing_comment_id response: response_length=${response_length}" >&2

    [[ -z "$response" || "$response" == "[]" ]] && break

    if ! jq -e . >/dev/null 2>&1 <<<"$response"; then
      echo "Debug find_existing_comment_id: non-JSON response, aborting lookup." >&2
      break
    fi

    id="$(jq -r --arg marker "$marker" 'map(select((.body // "") | contains($marker))) | first? | .id // empty' <<<"$response" 2>/dev/null || true)"
    echo "Debug find_existing_comment_id state: page=${page} response_length=${response_length} current_id=${id}" >&2

    if [[ -n "$id" ]]; then
      echo "Found existing comment id: ${id}" >&2
      echo "$id"
      return
    fi

    page=$((page + 1))
    if [[ "$(jq -r 'length' <<<"$response" 2>/dev/null || echo 0)" -lt 100 ]]; then
      break
    fi
  done

  if [[ -n "$id" ]]; then
    echo "Found existing comment id: ${id}" >&2
    echo "$id"
  else
    echo "No existing comment with marker found." >&2
  fi
}

if (( base_packages_available )) && (( ${#new_packages[@]} > 0 )) && [[ -n "${GITHUB_TOKEN:-}" ]]; then
  if [[ -n "$pr_number" ]]; then
    api_url="${GITHUB_API_URL:-https://api.github.com}"
    comment_marker="<!-- composer-license-audit:new-packages -->"
    comment_title="### Composer License Audit"
    comment_timestamp="Last checked at \`$(date -u +"%Y-%m-%d %H:%M:%S") UTC\`"
    comment_body="$comment_marker
${comment_title}
#### New packages
"
    if (( allowed_check_enabled )); then
      comment_body+="| Package | Version | Licenses | Status |
| --- | --- | --- | --- |
"
      for row in "${new_packages[@]}"; do
        IFS=$'\t' read -r name version licenses <<<"$row"
        [[ -z "$name" ]] && continue
        status_icon="$(license_status_icon "$licenses")"
        comment_body+="| ${name} | ${version} | ${licenses} | ${status_icon} |
"
      done
    else
      comment_body+="| Package | Version | Licenses |
| --- | --- | --- |
"
      for row in "${new_packages[@]}"; do
        IFS=$'\t' read -r name version licenses <<<"$row"
        [[ -z "$name" ]] && continue
        comment_body+="| ${name} | ${version} | ${licenses} |
"
      done
    fi
    comment_body+="

<details>
<summary>All packages</summary>

"
    if (( allowed_check_enabled )); then
      comment_body+="| Package | Version | Licenses | Status |
| --- | --- | --- | --- |
"
      while IFS=$'\t' read -r name version licenses; do
        [[ -z "$name" ]] && continue
        status_icon="$(license_status_icon "$licenses")"
        comment_body+="| ${name} | ${version} | ${licenses} | ${status_icon} |
"
      done <<< "$package_details_tsv"
    else
      comment_body+="| Package | Version | Licenses |
| --- | --- | --- |
"
      while IFS=$'\t' read -r name version licenses; do
        [[ -z "$name" ]] && continue
        comment_body+="| ${name} | ${version} | ${licenses} |
"
      done <<< "$package_details_tsv"
    fi
    comment_body+="
</details>

${comment_timestamp}"

    existing_id="$(find_existing_comment_id "$api_url" "$pr_number" "$comment_marker")"

    if [[ -n "$existing_id" ]]; then
      curl -sS -X PATCH \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${api_url}/repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" \
        -d "$(jq -cn --arg body "$comment_body" '{body:$body}')" >/dev/null || true
      echo "Updated pull request license summary comment (${existing_id})."
    else
      curl -sS -X POST \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${api_url}/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments" \
        -d "$(jq -cn --arg body "$comment_body" '{body:$body}')" >/dev/null || true
      echo "Created pull request license summary comment."
    fi
  fi
elif (( base_packages_available )) && [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Skipping PR comment: GITHUB_TOKEN not set or empty."
elif (( base_packages_available )) && [[ -z "$pr_number" ]]; then
  echo "Skipping PR comment: pull request number not available."
elif (( base_packages_available )) && (( ${#new_packages[@]} == 0 )); then
  echo "No new packages found; posting informational PR comment."
  api_url="${GITHUB_API_URL:-https://api.github.com}"
  comment_marker="<!-- composer-license-audit:new-packages -->"
  comment_timestamp="Last checked at \`$(date -u +"%Y-%m-%d %H:%M:%S") UTC\`"
  comment_body="$comment_marker
### Composer License Audit

No new packages detected in this pull request.

<details>
<summary>All packages</summary>

"
  if (( allowed_check_enabled )); then
    comment_body+="| Package | Version | Licenses | Status |
| --- | --- | --- | --- |
"
    while IFS=$'\t' read -r name version licenses; do
      [[ -z "$name" ]] && continue
      status_icon="$(license_status_icon "$licenses")"
      comment_body+="| ${name} | ${version} | ${licenses} | ${status_icon} |
"
    done <<< "$package_details_tsv"
  else
    comment_body+="| Package | Version | Licenses |
| --- | --- | --- |
"
    while IFS=$'\t' read -r name version licenses; do
      [[ -z "$name" ]] && continue
      comment_body+="| ${name} | ${version} | ${licenses} |
"
    done <<< "$package_details_tsv"
  fi
  comment_body+="
</details>

${comment_timestamp}"

  existing_id="$(find_existing_comment_id "$api_url" "$pr_number" "$comment_marker")"

  if [[ -n "$existing_id" ]]; then
    curl -sS -X PATCH \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${api_url}/repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" \
      -d "$(jq -cn --arg body "$comment_body" '{body:$body}')" >/dev/null || true
    echo "Updated pull request license summary comment (${existing_id}) to note no new packages."
  else
    curl -sS -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${api_url}/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments" \
      -d "$(jq -cn --arg body "$comment_body" '{body:$body}')" >/dev/null || true
    echo "Created pull request license summary comment noting no new packages."
  fi
fi

if (( allowed_check_enabled && fail_hard_enabled && violations_found )); then
  echo "Found disallowed licenses not in the allowed list." >&2
  exit 1
fi
