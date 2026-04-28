#!/bin/bash
export SONAR_PROJECT_NAME="${SONAR_PROJECT_NAME:-$(basename "$(pwd)")}"
export SONAR_GITROOT=${SONAR_GITROOT:-"$(pwd)"}
export SONAR_METRICS_PATH=${SONAR_METRICS_PATH:-"./sonar-metrics.json"}

function generate_new_findings_md() {
  local new_issues_report_json_path="$1"
  local new_hotspots_report_json_path="$2"
  local repository="$3"
  local commit_sha="$4"
  local max_findings="${5:-25}"

  # Keep PR comments useful without becoming unreadable on large changes.
  jq -rs \
    --arg repository "$repository" \
    --arg commit_sha "$commit_sha" \
    --argjson max_findings "$max_findings" '
    def md_escape:
      tostring
      | gsub("\\|"; "\\|")
      | gsub("\\*"; "\\*")
      | gsub("_"; "\\_")
      | gsub("`"; "\\`")
      | gsub("\\["; "\\[")
      | gsub("\\]"; "\\]")
      | gsub("<"; "\\<")
      | gsub(">"; "\\>");

    def file_path:
      (.component // "" | split(":") | if length > 1 then .[1] else .[0] end);

    def line_number:
      (.line // 1);

    def finding_kind:
      (.type // "SECURITY_HOTSPOT");

    def finding_severity:
      (.severity // .vulnerabilityProbability // "-");

    def finding_rule:
      (.rule // .ruleKey // "-");

    def finding_url:
      "https://github.com/\($repository)/blob/\($commit_sha)/\(file_path)#L\(line_number)";

    ((.[0] // []) + (.[1] // [])) as $findings |
    if ($findings | length) == 0 then
      ""
    else
      "### New findings\n" +
      "| Type | Severity | Location | Rule | Message |\n" +
      "|------|----------|----------|------|---------|\n" +
      (
        $findings[0:$max_findings]
        | map(
          "| \(finding_kind | md_escape) | \(finding_severity | md_escape) | " +
          "[\(file_path | md_escape):\(line_number)](\(finding_url)) | " +
          "\(finding_rule | md_escape) | \((.message // "") | md_escape) |"
        )
        | join("\n")
      ) +
      (
        if ($findings | length) > $max_findings then
          "\n\n_Showing first \($max_findings) of \($findings | length) new findings._"
        else
          ""
        end
      ) +
      "\n\n"
    end
  ' "$new_issues_report_json_path" "$new_hotspots_report_json_path"
}

function emit_github_annotations() {
  local new_issues_report_json_path="$1"
  local new_hotspots_report_json_path="$2"

  # GitHub workflow commands create line-level annotations in the check run without failing the workflow.
  jq -rs '
    def command_escape:
      tostring
      | gsub("%"; "%25")
      | gsub("\r"; "%0D")
      | gsub("\n"; "%0A");

    def property_escape:
      command_escape
      | gsub(":"; "%3A")
      | gsub(","; "%2C");

    def file_path:
      (.component // "" | split(":") | if length > 1 then .[1] else .[0] end);

    def line_number:
      (.line // 1);

    def finding_kind:
      (.type // "SECURITY_HOTSPOT");

    def finding_rule:
      (.rule // .ruleKey // "-");

    ((.[0] // []) + (.[1] // []))[] |
      "::warning file=\(file_path | property_escape),line=\(line_number),title=\((finding_kind + " " + finding_rule) | property_escape)::\((.message // "") | command_escape)"
  ' "$new_issues_report_json_path" "$new_hotspots_report_json_path"
}

function generate_issues_report_md() {
  local input_json_path="$1"
  local output_md_path="$2"

  {
    echo "### 🌟 **Scanwise overall Issues Details for $SONAR_PROJECT_NAME** 🌟"
    echo "| Type | Severity | File | Line | Effort | Author | Rule | Message |"
    echo "|------|----------|------|------|--------|--------|------|---------|"
    jq -r '
      .[] |
      "| \(.type) | \(.severity) | \(.component | split(":")[1] | gsub("_"; "\\_")) | \(.line // "-") | " +
      "\(.effort) | \(.author | gsub("_"; "\\_")) | \(.rule) | " +
      (.message
        | gsub("\\|"; "\\|")
        | gsub("\\*"; "\\*")
        | gsub("_"; "\\_")
        | gsub("`"; "\\`")
        | gsub("\\["; "\\[")
        | gsub("\\]"; "\\]")
        | gsub("<"; "\\<")
        | gsub(">"; "\\>")
      ) + " |"
    ' "${input_json_path}"
  } > "${output_md_path}"
}

function generate_hotspots_report_md() {
  local input_json_path="$1"
  local output_md_path="$2"
  
  {
    echo "### 🌟 **Scanwise overall security hotspots to review for $SONAR_PROJECT_NAME** 🌟";
    echo "| Category | Vuln. Probability | File | Line | Author | Rule | Message |";
    echo "|----------|-------------------|------|------|--------|------|---------|";
    jq -r '
      .[] |
      "| \(.securityCategory) | \(.vulnerabilityProbability) | \(.component | split(":")[1] | gsub("_"; "\\_")) | \(.line // "-") | \(.author | gsub("_"; "\\_")) | \(.ruleKey) | " +
      (.message
        | gsub("\\|"; "\\|")
        | gsub("\\*"; "\\*")
        | gsub("_"; "\\_")
        | gsub("`"; "\\`")
        | gsub("\\["; "\\[")
        | gsub("\\]"; "\\]")
        | gsub("<"; "\\<")
        | gsub(">"; "\\>")
      ) + " |"
    ' "${input_json_path}";
  } > "${output_md_path}"
}

function generate_scanwise_analysis_summary_md() {
  local new_issues_report_json_path="$1"
  local new_hotspots_report_json_path="$2"
  local new_code_reports_link="$3"
  local overall_code_reports_link="$4"
  local repository="${5:-}"
  local commit_sha="${6:-}"

  # Extract metrics for New Code
  local new_code_smells=$(jq '[.[] | select(.type == "CODE_SMELL")] | length' "$new_issues_report_json_path")
  local new_bugs=$(jq '[.[] | select(.type == "BUG")] | length' "$new_issues_report_json_path")
  local new_vulnerabilities=$(jq '[.[] | select(.type == "VULNERABILITY")] | length' "$new_issues_report_json_path")
  local new_security_hotspots=$(jq 'length' "$new_hotspots_report_json_path")

  # Load Scanwise JSON Metrics Report
  local overall_metrics_json_path=$(cat "${SONAR_GITROOT}/${SONAR_METRICS_PATH}")

  # Extract Metrics for Overall Code
  local name=$(echo "$overall_metrics_json_path" | jq -r '.component.name')
  local ncloc=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "ncloc") | .value')
  local code_smells=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "code_smells") | .value')
  local bugs=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "bugs") | .value')
  local vulnerabilities=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "vulnerabilities") | .value')
  local security_hotspots=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "security_hotspots") | .value')
  local sqale_rating=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "sqale_rating") | .value')
  local reliability_rating=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "reliability_rating") | .value')
  local security_rating=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "security_rating") | .value')
  local coverage=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "coverage") | .value')
  local duplicated_lines_density=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "duplicated_lines_density") | .value')
  local quality_gate_status=$(echo "$overall_metrics_json_path" | jq -r '.component.measures[] | select(.metric == "quality_gate_details") | .value | fromjson | .level')

  # Helper function to generate stars
  generate_stars() {
    local rating=$1
    # Round rating to nearest integer if it's a float
    local rounded_rating=$(printf "%.0f" "$rating")

    # Build full stars (★) and empty stars (☆)
    local full_stars=$(printf '★%.0s' $(seq 1 $((6 - rounded_rating))))
    local empty_stars=$(printf '☆%.0s' $(seq 1  $((rounded_rating - 1))))

    if [[ $((6 - rounded_rating)) -eq 5 ]]; then
      echo "$full_stars"
    else
      echo "$full_stars$empty_stars"
    fi
  }

  # Generate Ratings
  local sqale_stars=$(generate_stars "$sqale_rating")
  local reliability_stars=$(generate_stars "$reliability_rating")
  local security_stars=$(generate_stars "$security_rating")

  # Build the summary
  local summary="# 🌟 **Scanwise Analysis Summary for $name** 🌟\n\n"

  summary="$summary## 🆕 New code statistics 🆕\n\n"

  summary="$summary### Key values\n"
  summary="$summary- **💡 Code Smells:** $new_code_smells\n"
  summary="$summary- **🐞 Bugs:** $new_bugs\n"
  summary="$summary- **🔒 Vulnerabilities:** $new_vulnerabilities\n"
  summary="$summary- **🔥 Security Hotspots:** $new_security_hotspots\n\n"

  if [ "$repository" != "" ] && [ "$commit_sha" != "" ]; then
    # Link every new issue to the exact source line so the PR comment is actionable even without artifacts.
    summary="$summary$(generate_new_findings_md "$new_issues_report_json_path" "$new_hotspots_report_json_path" "$repository" "$commit_sha")"
  fi

  if [ "$new_code_reports_link" != "" ]; then
    summary="$summary### Issues and Security Hotspots Reports\n"
    summary="${summary}[Click here to download the reports](${new_code_reports_link})\n\n"
  fi

  summary="$summary## 🔁 Overall code statistics 🔁\n\n"
  summary="$summary### Key values\n"
  summary="$summary- **📊 Lines of Code (LoC):** $ncloc\n"
  summary="$summary- **💡 Code Smells:** $code_smells\n"
  summary="$summary- **🐞 Bugs:** $bugs\n"
  summary="$summary- **🔒 Vulnerabilities:** $vulnerabilities\n"
  summary="$summary- **🔥 Security Hotspots:** $security_hotspots\n\n"

  summary="$summary### Ratings\n"
  summary="$summary- **💎 Maintainability:** $sqale_stars\n"
  summary="$summary- **⚙️ Reliability:** $reliability_stars\n"
  summary="$summary- **🔐 Security:** $security_stars\n"
  summary="$summary- **🛡 Test Coverage:** $coverage%\n"
  summary="$summary- **🌀 Duplicated Lines Density:** $duplicated_lines_density%\n\n"

  summary="$summary### Quality Gate\n"
  summary="$summary- **Status:** $(if [ "$quality_gate_status" = "OK" ]; then echo "✅ **PASSED**"; else echo "❌ **FAILED**"; fi)\n\n"

  if [ "$overall_code_reports_link" != "" ]; then
    summary="$summary### Issues and Security Hotspots Reports\n"
    summary="${summary}[Click here to download the reports](${overall_code_reports_link})"
  fi

  printf "%b" "$summary"
}

"$@"
