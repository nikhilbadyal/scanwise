#!/bin/bash

set -euo pipefail

function decode_base64() {
  # macOS and GNU coreutils use different flags, so detect the supported decoder at runtime.
  if printf '' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

function extract_changed_right_lines_from_files_json() {
  local files_json_path="$1"
  local output_path="$2"

  # GitHub accepts inline review comments only on lines present in the PR diff's RIGHT side.
  : > "$output_path"
  jq -r '.[] | select(.patch != null) | @base64' "$files_json_path" | while IFS= read -r encoded_file; do
    local decoded_file
    local filename
    local patch

    decoded_file=$(printf '%s' "$encoded_file" | decode_base64)
    filename=$(printf '%s' "$decoded_file" | jq -r '.filename')
    patch=$(printf '%s' "$decoded_file" | jq -r '.patch')

    printf '%s\n' "$patch" | awk -v file="$filename" '
      /^@@ / {
        header = $0
        sub(/^.*\+/, "", header)
        sub(/[, ].*$/, "", header)
        new_line = header + 0
        next
      }
      new_line == "" {
        next
      }
      substr($0, 1, 1) == "+" && substr($0, 1, 3) != "+++" {
        print file ":" new_line
        new_line++
        next
      }
      substr($0, 1, 1) == " " {
        print file ":" new_line
        new_line++
        next
      }
      substr($0, 1, 1) == "-" {
        next
      }
    ' >> "$output_path"
  done

  # Deduplicate context lines that can appear in adjacent hunks.
  sort -u "$output_path" -o "$output_path"
}

function create_findings_json() {
  local issues_json_path="$1"
  local hotspots_json_path="$2"
  local output_path="$3"

  # Normalize issues and hotspots into one shape so comment creation is independent of Sonar finding type.
  jq -s '
    def file_path:
      (.component // "" | sub("^[^:]*:"; ""));

    def line_number:
      (.line // null);

    def finding_rule:
      (.rule // .ruleKey // "-");

    def finding_marker:
      (.key // ([finding_rule, file_path, (line_number | tostring), (.message // "")] | join("|") | @uri));

    ((.[0] // []) | map({
      marker: finding_marker,
      path: file_path,
      line: line_number,
      kind: (.type // "ISSUE"),
      severity: (.severity // "-"),
      rule: finding_rule,
      message: (.message // "")
    })) +
    ((.[1] // []) | map({
      marker: finding_marker,
      path: file_path,
      line: line_number,
      kind: "SECURITY_HOTSPOT",
      severity: (.vulnerabilityProbability // "-"),
      rule: finding_rule,
      message: (.message // "")
    }))
  ' "$issues_json_path" "$hotspots_json_path" > "$output_path"
}

function create_existing_markers_file() {
  local comments_json_path="$1"
  local output_path="$2"

  # Hidden markers let reruns skip comments already posted by this action for the same Sonar finding.
  jq -r '
    .[] |
    select(.user.login == "github-actions[bot]") |
    (.body // "") |
    capture("<!-- scanwise-finding:(?<marker>[^ ]+) -->").marker? // empty
  ' "$comments_json_path" | sort -u > "$output_path"
}

function build_comment_body() {
  local finding_json="$1"

  # Keep inline comments concise because the sticky summary links to full context and reports.
  jq -r '
    "**Scanwise \(.kind) (\(.severity))**\n\n" +
    "Rule: `\(.rule)`\n\n" +
    "\(.message)\n\n" +
    "<!-- scanwise-finding:\(.marker) -->"
  ' <<< "$finding_json"
}

function post_review_comment() {
  local repository="$1"
  local pull_request_number="$2"
  local commit_sha="$3"
  local path="$4"
  local line="$5"
  local body="$6"
  local payload_path

  payload_path=$(mktemp)

  # Use the modern line/side API instead of deprecated diff positions.
  jq -n \
    --arg body "$body" \
    --arg commit_id "$commit_sha" \
    --arg path "$path" \
    --argjson line "$line" \
    '{body: $body, commit_id: $commit_id, path: $path, line: $line, side: "RIGHT"}' > "$payload_path"

  if ! gh api --method POST "repos/${repository}/pulls/${pull_request_number}/comments" --input "$payload_path" >/dev/null; then
    # Inline comments are a convenience layer, so API rejections should not fail the scan or summary comment.
    echo "Scanwise could not create inline comment for ${path}:${line}; leaving it in the summary only." >&2
  fi

  rm -f "$payload_path"
}

function create_pr_review_comments() {
  local issues_json_path="$1"
  local hotspots_json_path="$2"
  local repository="$3"
  local pull_request_number="$4"
  local commit_sha="$5"
  local max_comments="${6:-20}"
  local temp_dir
  local files_json_path
  local comments_json_path
  local changed_lines_path
  local findings_json_path
  local existing_markers_path
  local created_count=0

  # Keep the optional comment layer from failing the scan when users pass a bad limit value.
  if ! [[ "$max_comments" =~ ^[0-9]+$ ]]; then
    echo "Scanwise inline comment limit '${max_comments}' is invalid; using 20." >&2
    max_comments=20
  fi

  # The summary and artifacts remain useful on runners that do not provide the GitHub CLI.
  if ! command -v gh >/dev/null 2>&1; then
    echo "Scanwise inline comments require the GitHub CLI; leaving findings in the summary only." >&2
    return 0
  fi

  temp_dir=$(mktemp -d)
  files_json_path="${temp_dir}/files.json"
  comments_json_path="${temp_dir}/comments.json"
  changed_lines_path="${temp_dir}/changed-lines.txt"
  findings_json_path="${temp_dir}/findings.json"
  existing_markers_path="${temp_dir}/existing-markers.txt"

  # Paginated API responses are arrays per page; slurping and adding gives one JSON array for jq processing.
  if ! gh api --paginate "repos/${repository}/pulls/${pull_request_number}/files" | jq -s 'add' > "$files_json_path"; then
    echo "Scanwise could not read PR files; leaving inline findings in the summary only." >&2
    rm -rf "$temp_dir"
    return 0
  fi

  if ! gh api --paginate "repos/${repository}/pulls/${pull_request_number}/comments" | jq -s 'add' > "$comments_json_path"; then
    echo "Scanwise could not read existing PR review comments; leaving inline findings in the summary only." >&2
    rm -rf "$temp_dir"
    return 0
  fi

  extract_changed_right_lines_from_files_json "$files_json_path" "$changed_lines_path"
  create_findings_json "$issues_json_path" "$hotspots_json_path" "$findings_json_path"
  create_existing_markers_file "$comments_json_path" "$existing_markers_path"

  jq -c '.[]' "$findings_json_path" | while IFS= read -r finding_json; do
    local marker
    local path
    local line
    local body

    marker=$(jq -r '.marker' <<< "$finding_json")
    path=$(jq -r '.path' <<< "$finding_json")
    line=$(jq -r '.line' <<< "$finding_json")

    # Line-less Sonar findings cannot be placed accurately in GitHub's diff comment model.
    if ! [[ "$line" =~ ^[0-9]+$ ]]; then
      continue
    fi

    # Skip findings that GitHub cannot place inline because the exact head-side line is not in the PR diff.
    if ! grep -Fxq "${path}:${line}" "$changed_lines_path"; then
      continue
    fi

    # Skip findings already commented on by a previous run to avoid duplicate review threads.
    if grep -Fxq "$marker" "$existing_markers_path"; then
      continue
    fi

    if [ "$created_count" -ge "$max_comments" ]; then
      break
    fi

    body=$(build_comment_body "$finding_json")
    post_review_comment "$repository" "$pull_request_number" "$commit_sha" "$path" "$line" "$body"
    created_count=$((created_count + 1))
  done

  rm -rf "$temp_dir"
}

"$@"
