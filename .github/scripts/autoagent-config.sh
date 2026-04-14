#!/usr/bin/env bash
# .github/scripts/autoagent-config.sh
# Source (don't exec) to load config into the current shell:
#   source .github/scripts/autoagent-config.sh

set -euo pipefail

CONFIG_PATH="${AUTOAGENT_CONFIG:-.github/autoagent-config.yml}"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "autoagent-config: missing $CONFIG_PATH" >&2
  return 1 2>/dev/null || exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "autoagent-config: yq not on PATH. Install it via the mikefarah/yq action in the workflow, or locally with 'brew install yq' / 'snap install yq'." >&2
  return 1 2>/dev/null || exit 1
fi

_cfg() { yq -r "$1" "$CONFIG_PATH"; }

# GitHub
export AUTOAGENT_ORG="$(_cfg '.github.organization')"
export AUTOAGENT_REPO="$(_cfg '.github.repository')"
export AUTOAGENT_PROJECT_NUMBER="$(_cfg '.github.project_number')"

# Board
export AUTOAGENT_STATUS_FIELD="$(_cfg '.board.status_field')"
export AUTOAGENT_COL_TODO="$(_cfg '.board.columns.todo')"
export AUTOAGENT_COL_IN_PROGRESS="$(_cfg '.board.columns.in_progress')"
export AUTOAGENT_COL_READY_FOR_QA="$(_cfg '.board.columns.ready_for_qa')"
export AUTOAGENT_COL_DONE="$(_cfg '.board.columns.done')"

# Milestones / iterations
export AUTOAGENT_USE_ITERATIONS="$(_cfg '.milestones.use_iterations')"
export AUTOAGENT_MILESTONE_FORMAT="$(_cfg '.milestones.format')"
export AUTOAGENT_ITERATION_FIELD="$(_cfg '.milestones.iteration_field')"
export AUTOAGENT_DONE_STATUS="$(_cfg '.milestones.done_status')"

# Labels
export AUTOAGENT_LABEL_PLAN="$(_cfg '.labels.plan')"
export AUTOAGENT_LABEL_HIGH_RISK="$(_cfg '.labels.high_risk')"
export AUTOAGENT_LABEL_MEDIUM_RISK="$(_cfg '.labels.medium_risk')"
export AUTOAGENT_LABEL_LOW_RISK="$(_cfg '.labels.low_risk')"

# Branch
export AUTOAGENT_BRANCH_PREFIX="$(_cfg '.branch.prefix')"

# Severity keywords (pipe-joined for use in grep -E)
export AUTOAGENT_SEVERITY_REGEX="$(yq -r '[.severity_keywords.blocking[] | "\\b" + . + "\\b"] | join("|")' "$CONFIG_PATH")"

# Agents
for agent in planner implementer fixer merger; do
  UPPER=$(echo "$agent" | tr '[:lower:]' '[:upper:]')
  export "AUTOAGENT_${UPPER}_ENABLED=$(_cfg ".agents.${agent}.enabled")"
  export "AUTOAGENT_${UPPER}_MODEL=$(_cfg ".agents.${agent}.model")"
  export "AUTOAGENT_${UPPER}_TIMEOUT=$(_cfg ".agents.${agent}.timeout_minutes // 60")"
done
export AUTOAGENT_IMPLEMENTER_MAX_TURNS="$(_cfg '.agents.implementer.max_turns')"
export AUTOAGENT_IMPLEMENTER_TEST_RETRY_BUDGET="$(_cfg '.agents.implementer.test_retry_budget')"
export AUTOAGENT_FIXER_MAX_TURNS="$(_cfg '.agents.fixer.max_turns')"
export AUTOAGENT_PLANNER_MAX_TURNS="$(_cfg '.agents.planner.max_turns')"
export AUTOAGENT_MERGER_METHOD="$(_cfg '.agents.merger.merge_method')"
export AUTOAGENT_MERGER_PAUSE="$(_cfg '.agents.merger.pause_seconds')"

# Notifications
export AUTOAGENT_NOTIFY_PROVIDER="$(_cfg '.notifications.provider')"

# Runner
export AUTOAGENT_RUNNER_LABELS="$(_cfg '.runner.labels')"

# Validation: refuse placeholder strings in CI.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  case "$AUTOAGENT_ORG" in
    your-org|your-*|"")
      echo "autoagent-config: .github.organization is still '$AUTOAGENT_ORG' — set it in .github/autoagent-config.yml" >&2
      return 1 2>/dev/null || exit 1
      ;;
  esac
  case "$AUTOAGENT_REPO" in
    your-org/*|your-*|"")
      echo "autoagent-config: .github.repository is still '$AUTOAGENT_REPO'" >&2
      return 1 2>/dev/null || exit 1
      ;;
  esac
fi

echo "autoagent-config: loaded (org=$AUTOAGENT_ORG repo=$AUTOAGENT_REPO project=$AUTOAGENT_PROJECT_NUMBER provider=$AUTOAGENT_NOTIFY_PROVIDER)" >&2
