#!/bin/bash

# Unit tests for create-pr-review-comments.sh

# Import shared assertions so this test uses the same failure output as the existing suite.
source "$(dirname "$0")/../test_utils.sh"

# Path to the script under test; each test sources it so helper functions are available in isolation.
CREATE_REVIEW_COMMENTS_SCRIPT="$(dirname "$0")/../../create-pr-review-comments.sh"

test_extract_changed_right_lines_from_files_json() {
  local files_json
  local output_file
  local patch
  local content

  # GitHub only accepts inline comments on diff-visible RIGHT-side lines, so this parser is the safety gate.
  files_json=$(mktemp)
  output_file=$(mktemp)
  patch=$'@@ -0,0 +1,5 @@\n+// Test probe for Scanwise PR review comments\n+export function scanwisePrProbe(userInput) {\n+  // This added line keeps the target finding line realistic.\n+  return eval(userInput);\n+}\n'

  jq -n --arg patch "$patch" '[{filename: "scanwise_pr_probe.js", patch: $patch}]' > "$files_json"

  bash -c "source $CREATE_REVIEW_COMMENTS_SCRIPT && extract_changed_right_lines_from_files_json $files_json $output_file" 2>&1

  content=$(cat "$output_file")
  assert_contains "$content" "scanwise_pr_probe.js:4"

  rm "$files_json" "$output_file"

  echo "✅ test_extract_changed_right_lines_from_files_json passed"
}

test_create_findings_json() {
  local issues_file
  local hotspots_file
  local output_file
  local content

  # Sonar issues and hotspots use different schemas, so inline comments need one normalized shape.
  issues_file=$(mktemp)
  hotspots_file=$(mktemp)
  output_file=$(mktemp)

  echo "[]" > "$issues_file"
  jq -n '[
    {
      key: "hotspot-key",
      component: "hilmail-api:scanwise_pr_probe.js",
      line: 4,
      ruleKey: "javascript:S1523",
      vulnerabilityProbability: "HIGH",
      message: "Make sure this code is not vulnerable to code injection."
    }
  ]' > "$hotspots_file"

  bash -c "source $CREATE_REVIEW_COMMENTS_SCRIPT && create_findings_json $issues_file $hotspots_file $output_file" 2>&1

  content=$(cat "$output_file")
  assert_contains "$content" '"marker": "hotspot-key"'
  assert_contains "$content" '"path": "scanwise_pr_probe.js"'
  assert_contains "$content" '"line": 4'
  assert_contains "$content" '"kind": "SECURITY_HOTSPOT"'
  assert_contains "$content" '"rule": "javascript:S1523"'

  rm "$issues_file" "$hotspots_file" "$output_file"

  echo "✅ test_create_findings_json passed"
}

test_create_existing_markers_file() {
  local comments_file
  local output_file
  local content

  # Hidden markers make repeated workflow runs idempotent without editing or deleting existing review threads.
  comments_file=$(mktemp)
  output_file=$(mktemp)

  jq -n '[
    {
      user: {login: "github-actions[bot]"},
      body: "Existing Scanwise note\n\n<!-- scanwise-finding:hotspot-key -->"
    },
    {
      user: {login: "someone-else"},
      body: "<!-- scanwise-finding:ignored-marker -->"
    }
  ]' > "$comments_file"

  bash -c "source $CREATE_REVIEW_COMMENTS_SCRIPT && create_existing_markers_file $comments_file $output_file" 2>&1

  content=$(cat "$output_file")
  assert_equals "$content" "hotspot-key"

  rm "$comments_file" "$output_file"

  echo "✅ test_create_existing_markers_file passed"
}

test_build_comment_body() {
  local finding_json
  local output

  # Inline comments should be short because the sticky PR summary remains the complete report.
  finding_json=$(jq -n -c '{
    marker: "hotspot-key",
    kind: "SECURITY_HOTSPOT",
    severity: "HIGH",
    rule: "javascript:S1523",
    message: "Make sure this code is not vulnerable to code injection."
  }')

  output=$(bash -c "source $CREATE_REVIEW_COMMENTS_SCRIPT && build_comment_body '$finding_json'" 2>&1)

  assert_contains "$output" "**Scanwise SECURITY_HOTSPOT (HIGH)**"
  assert_contains "$output" 'Rule: `javascript:S1523`'
  assert_contains "$output" "Make sure this code is not vulnerable to code injection."
  assert_contains "$output" "<!-- scanwise-finding:hotspot-key -->"

  echo "✅ test_build_comment_body passed"
}

test_create_pr_review_comments_filters_and_dedupes() {
  local issues_file
  local hotspots_file
  local files_json
  local comments_json
  local posted_file
  local patch
  local content

  # This end-to-end helper test proves the noisy cases stay in the summary instead of becoming review threads.
  issues_file=$(mktemp)
  hotspots_file=$(mktemp)
  files_json=$(mktemp)
  comments_json=$(mktemp)
  posted_file=$(mktemp)
  patch=$'@@ -0,0 +1,5 @@\n+// Test probe for Scanwise PR review comments\n+export function scanwisePrProbe(userInput) {\n+  // This added line keeps the target finding line realistic.\n+  return eval(userInput);\n+}\n'

  jq -n --arg patch "$patch" '[{filename: "scanwise_pr_probe.js", patch: $patch}]' > "$files_json"
  jq -n '[
    {
      key: "ISSUE-POST",
      component: "hilmail-api:scanwise_pr_probe.js",
      line: 4,
      rule: "javascript:S1523",
      severity: "CRITICAL",
      type: "VULNERABILITY",
      message: "Avoid evaluating user input."
    },
    {
      key: "ISSUE-OFFDIFF",
      component: "hilmail-api:scanwise_pr_probe.js",
      line: 99,
      rule: "javascript:S9999",
      severity: "MAJOR",
      type: "CODE_SMELL",
      message: "This line is not visible in the PR diff."
    }
  ]' > "$issues_file"
  jq -n '[
    {
      key: "HOTSPOT-EXISTING",
      component: "hilmail-api:scanwise_pr_probe.js",
      line: 5,
      ruleKey: "javascript:S2068",
      vulnerabilityProbability: "HIGH",
      message: "This already has a review comment."
    }
  ]' > "$hotspots_file"
  jq -n '[
    {
      user: {login: "github-actions[bot]"},
      body: "Already posted\n\n<!-- scanwise-finding:HOTSPOT-EXISTING -->"
    }
  ]' > "$comments_json"

  CREATE_REVIEW_COMMENTS_SCRIPT="$CREATE_REVIEW_COMMENTS_SCRIPT" \
    files_json="$files_json" \
    comments_json="$comments_json" \
    issues_file="$issues_file" \
    hotspots_file="$hotspots_file" \
    posted_file="$posted_file" \
    bash -c '
      source "$CREATE_REVIEW_COMMENTS_SCRIPT"

      # The GitHub CLI is mocked so the test exercises filtering without touching the network.
      function gh {
        if [[ "$*" == *"/files" ]]; then
          cat "$files_json"
          return 0
        fi

        if [[ "$*" == *"/comments" ]]; then
          cat "$comments_json"
          return 0
        fi

        return 1
      }

      # Capturing posts keeps the test focused on which findings would be commented inline.
      function post_review_comment {
        printf "%s\t%s\t%s\n" "$4" "$5" "$6" >> "$posted_file"
      }

      create_pr_review_comments "$issues_file" "$hotspots_file" owner/repo 123 abc123 20
    ' 2>&1

  content=$(cat "$posted_file")
  assert_contains "$content" $'scanwise_pr_probe.js\t4'
  assert_contains "$content" "ISSUE-POST"
  assert_not_contains "$content" "ISSUE-OFFDIFF"
  assert_not_contains "$content" "HOTSPOT-EXISTING"

  rm "$issues_file" "$hotspots_file" "$files_json" "$comments_json" "$posted_file"

  echo "✅ test_create_pr_review_comments_filters_and_dedupes passed"
}

# Run all tests in a predictable order so failures point directly at the broken transformation.
run_tests() {
  test_extract_changed_right_lines_from_files_json
  test_create_findings_json
  test_create_existing_markers_file
  test_build_comment_body
  test_create_pr_review_comments_filters_and_dedupes

  echo "✅ All create-pr-review-comments.sh tests passed"
}

# Execute the unit tests when the file is invoked by the repository test runner.
run_tests
