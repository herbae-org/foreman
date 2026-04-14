#!/usr/bin/env bash
# .github/scripts/test-autoagent-config.sh
# Run locally: bash .github/scripts/test-autoagent-config.sh

set -euo pipefail
cd "$(dirname "$0")/../.."

# Use $HOME as tmpdir base so snap-confined yq can read the file.
# In CI yq is installed via the mikefarah/yq action (not snap) so /tmp works there.
TMP=$(mktemp -d --tmpdir="$HOME")
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/config.yml" <<'YAML'
github:
  organization: "acme"
  repository: "acme/robot"
  project_number: 7
board:
  status_field: "Status"
  columns: {todo: "Backlog", in_progress: "Doing", ready_for_qa: "Review", done: "Shipped"}
milestones:
  use_iterations: true
  format: "YY CW WW"
  iteration_field: "Sprint"
  done_status: "Shipped"
labels:
  priorities: ["p0","p1"]
  plan: "plan"
  high_risk: "risk/high"
  medium_risk: "risk/medium"
  low_risk: "risk/low"
branch: {prefix: "autoagent/"}
severity_keywords: {blocking: ["CRITICAL","MEDIUM"]}
agents:
  planner:     {enabled: true, model: "claude-sonnet-4-6", max_turns: 80,  timeout_minutes: 20}
  implementer: {enabled: true, model: "claude-opus-4-6",   max_turns: 500, timeout_minutes: 90, test_retry_budget: 3}
  fixer:       {enabled: true, model: "claude-sonnet-4-6", max_turns: 500, timeout_minutes: 60}
  merger:      {enabled: true, model: "claude-sonnet-4-6", merge_method: "squash", pause_seconds: 5}
notifications:
  provider: "none"
  telegram: {bot_token_secret: "X", chat_id_secret: "Y"}
  slack:    {webhook_secret: "Z"}
runner: {labels: "ubuntu-latest"}
YAML

AUTOAGENT_CONFIG="$TMP/config.yml" source .github/scripts/autoagent-config.sh

fail() { echo "FAIL: $1" >&2; exit 1; }
[ "$AUTOAGENT_ORG" = "acme" ]                      || fail "org"
[ "$AUTOAGENT_REPO" = "acme/robot" ]               || fail "repo"
[ "$AUTOAGENT_PROJECT_NUMBER" = "7" ]              || fail "project_number"
[ "$AUTOAGENT_COL_IN_PROGRESS" = "Doing" ]         || fail "col_in_progress"
[ "$AUTOAGENT_USE_ITERATIONS" = "true" ]           || fail "use_iterations"
[ "$AUTOAGENT_SEVERITY_REGEX" = '\bCRITICAL\b|\bMEDIUM\b' ] || fail "severity_regex: got '$AUTOAGENT_SEVERITY_REGEX'"
[ "$AUTOAGENT_MERGER_METHOD" = "squash" ]          || fail "merger_method"
[ "$AUTOAGENT_IMPLEMENTER_TEST_RETRY_BUDGET" = "3" ] || fail "retry_budget"
[ "$AUTOAGENT_NOTIFY_PROVIDER" = "none" ]          || fail "provider"

echo "PASS: autoagent-config.sh loaded all expected keys"

# Negative test: missing required key must fail cleanly.
BAD=$(mktemp --tmpdir="$HOME")
cat > "$BAD" <<'YAML'
github: {}   # organization, repository, project_number all missing
board:
  status_field: "Status"
  columns: {todo: "T", in_progress: "IP", ready_for_qa: "Q", done: "D"}
milestones: {use_iterations: false, format: "YY CW WW", iteration_field: "F", done_status: "D"}
labels: {priorities: [], plan: "plan", high_risk: "r/h", medium_risk: "r/m", low_risk: "r/l"}
branch: {prefix: "autoagent/"}
severity_keywords: {blocking: ["X"]}
agents:
  planner: {enabled: true, model: "x", max_turns: 1, timeout_minutes: 1}
  implementer: {enabled: true, model: "x", max_turns: 1, timeout_minutes: 1, test_retry_budget: 1}
  fixer: {enabled: true, model: "x", max_turns: 1, timeout_minutes: 1}
  merger: {enabled: true, model: "x", merge_method: "merge", pause_seconds: 1}
notifications: {provider: "none", telegram: {bot_token_secret: "x", chat_id_secret: "y"}, slack: {webhook_secret: "z"}}
runner: {labels: "ubuntu-latest"}
YAML
# Run in a subshell so the loader's `return 1` doesn't exit the harness.
OUTPUT=$(AUTOAGENT_CONFIG="$BAD" bash -c 'source .github/scripts/autoagent-config.sh' 2>&1 || true)
rm -f "$BAD"
echo "$OUTPUT" | grep -q "AUTOAGENT_ORG is missing or null" \
  || { echo "FAIL: negative test did not produce expected error. got:"; echo "$OUTPUT"; exit 1; }
echo "PASS: negative test — missing required key is rejected"
