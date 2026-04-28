#!/bin/bash

# Unit tests for run-pre-scan-script.sh

# Import test script
source "$(dirname "$0")/../test_utils.sh"

# Use an absolute script path because some tests intentionally change the working directory.
PRE_SCAN_SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/run-pre-scan-script.sh"

test_empty_pre_scan_script_is_noop() {
  # Empty configuration should succeed so callers can use the helper unconditionally.
  assert_success "bash $PRE_SCAN_SCRIPT ''"

  echo "✅ test_empty_pre_scan_script_is_noop passed"
}

test_inline_pre_scan_script_runs() {
  # Inline scripts are common in workflows, so verify multi-command text is executed from the workspace.
  tmp_dir=$(mktemp -d)
  output_file="$tmp_dir/inline-output.txt"

  (
    cd "$tmp_dir" || exit 1
    bash "$PRE_SCAN_SCRIPT" "printf '%s\n' inline-ok > '$output_file'"
  )

  assert_file_exists "$output_file"
  assert_contains "$(cat "$output_file")" "inline-ok"

  rm -rf "$tmp_dir"

  echo "✅ test_inline_pre_scan_script_runs passed"
}

test_file_pre_scan_script_runs() {
  # File scripts should run directly because repositories often keep build setup in versioned shell files.
  tmp_dir=$(mktemp -d)
  setup_file="$tmp_dir/setup.sh"
  output_file="$tmp_dir/file-output.txt"

  cat > "$setup_file" << EOF
#!/bin/bash
printf '%s\n' file-ok > "$output_file"
EOF

  bash "$PRE_SCAN_SCRIPT" "$setup_file"

  assert_file_exists "$output_file"
  assert_contains "$(cat "$output_file")" "file-ok"

  rm -rf "$tmp_dir"

  echo "✅ test_file_pre_scan_script_runs passed"
}

# Run all tests
run_tests() {
  test_empty_pre_scan_script_is_noop
  test_inline_pre_scan_script_runs
  test_file_pre_scan_script_runs

  echo "✅ All run-pre-scan-script.sh tests passed"
}

# Run tests
run_tests
