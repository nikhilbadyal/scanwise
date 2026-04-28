#!/bin/bash

# Unit tests for generate-summary-and-reports.sh

# Import test script
source "$(dirname "$0")/../test_utils.sh"

# Path to the script to test
GENERATE_SUMMARY_SCRIPT="$(dirname "$0")/../../generate-summary-and-reports.sh"

test_generate_issues_report_md() {
  # Create temporary files for input and output
  input_file=$(mktemp)
  output_file=$(mktemp)
  
  # Create a JSON input file with test data (array format expected by jq)
  cat > "$input_file" << EOF
[
  {
    "type": "CODE_SMELL",
    "severity": "MAJOR",
    "component": "test:src/main/java/com/example/Test.java",
    "message": "Test issue",
    "line": 10,
    "rule": "java:S1234",
    "effort": "5min",
    "author": "test@example.com"
  }
]
EOF
  
  # Execute the function to test
  export SONAR_PROJECT_NAME="tests"
  bash -c "source $GENERATE_SUMMARY_SCRIPT && generate_issues_report_md $input_file $output_file" 2>&1
  
  # Check that the output file was created and contains the expected data
  assert_file_exists "$output_file"
  content=$(cat "$output_file")
  assert_contains "$content" "### 🌟 **Scanwise overall Issues Details for tests** 🌟"
  assert_contains "$content" "MAJOR"
  assert_contains "$content" "Test issue"
  
  # Clean up
  rm "$input_file" "$output_file"
  
  echo "✅ test_generate_issues_report_md passed"
}

test_generate_hotspots_report_md() {
  # Create temporary files for input and output
  input_file=$(mktemp)
  output_file=$(mktemp)
  
  # Create a JSON input file with test data (array format expected by jq)
  cat > "$input_file" << EOF
[
  {
    "vulnerabilityProbability": "MEDIUM",
    "component": "test:src/main/java/com/example/Test.java",
    "message": "Test hotspot",
    "line": 10,
    "ruleKey": "java:S1234",
    "securityCategory": "sql-injection",
    "author": "test@example.com"
  }
]
EOF
  
  # Execute the function to test
  export SONAR_PROJECT_NAME="tests"
  bash -c "source $GENERATE_SUMMARY_SCRIPT && generate_hotspots_report_md $input_file $output_file" 2>&1
  
  # Check that the output file was created and contains the expected data
  assert_file_exists "$output_file"
  content=$(cat "$output_file")
  assert_contains "$content" "### 🌟 **Scanwise overall security hotspots to review for tests** 🌟"
  assert_contains "$content" "MEDIUM"
  assert_contains "$content" "Test hotspot"
  
  # Clean up
  rm "$input_file" "$output_file"
  
  echo "✅ test_generate_hotspots_report_md passed"
}

test_generate_new_findings_md() {
  # The PR summary should include exact clickable source locations without depending on artifacts.
  issues_file=$(mktemp)
  hotspots_file=$(mktemp)

  cat > "$issues_file" << EOF
[
  {
    "type": "VULNERABILITY",
    "severity": "CRITICAL",
    "component": "test:src/app.js",
    "message": "Avoid eval",
    "line": 4,
    "rule": "javascript:S1523"
  }
]
EOF

  cat > "$hotspots_file" << EOF
[
  {
    "vulnerabilityProbability": "HIGH",
    "component": "test:src/config.js",
    "message": "Review secret handling",
    "line": 8,
    "ruleKey": "javascript:S2068",
    "securityCategory": "auth"
  }
]
EOF

  output=$(bash -c "source $GENERATE_SUMMARY_SCRIPT && generate_new_findings_md $issues_file $hotspots_file owner/repo abc123" 2>&1)

  assert_contains "$output" "### New findings"
  assert_contains "$output" "[src/app.js:4](https://github.com/owner/repo/blob/abc123/src/app.js#L4)"
  assert_contains "$output" "javascript:S1523"
  assert_contains "$output" "[src/config.js:8](https://github.com/owner/repo/blob/abc123/src/config.js#L8)"

  rm "$issues_file" "$hotspots_file"

  echo "✅ test_generate_new_findings_md passed"
}

test_emit_github_annotations() {
  # GitHub annotations should point to the finding file and line while preserving the Sonar message.
  issues_file=$(mktemp)
  hotspots_file=$(mktemp)

  cat > "$issues_file" << EOF
[
  {
    "type": "CODE_SMELL",
    "severity": "MAJOR",
    "component": "test:src/app.js",
    "message": "Replace this console call",
    "line": 12,
    "rule": "javascript:S106"
  }
]
EOF

  echo "[]" > "$hotspots_file"

  output=$(bash -c "source $GENERATE_SUMMARY_SCRIPT && emit_github_annotations $issues_file $hotspots_file" 2>&1)

  assert_contains "$output" "::warning file=src/app.js,line=12,title=CODE_SMELL javascript%3AS106::Replace this console call"

  rm "$issues_file" "$hotspots_file"

  echo "✅ test_emit_github_annotations passed"
}

# Run all tests
run_tests() {
  test_generate_issues_report_md
  test_generate_hotspots_report_md
  test_generate_new_findings_md
  test_emit_github_annotations

  echo "✅ All generate-summary-and-reports.sh tests passed"
}

# Run tests
run_tests
