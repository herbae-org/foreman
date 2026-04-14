# AI Factory Adaptations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adapt the forked `leonardocardoso/three-body-agent` pipeline into an "AI Factory" MVP by (a) parameterising hardcoded per-project values into `.github/autoagent-config.yml`, (b) making notifications pluggable, (c) adding a Planner agent that produces a change-set and classifies risk so only high-risk work pauses for human review, (d) tightening the Implementer's inner test loop, and (e) refreshing the README + shipping an issue template.

**Architecture:** Stay within the existing shell + `gh` + `jq` + `envsubst` philosophy. Introduce one new shell helper (`.github/scripts/autoagent-config.sh`) that every agent workflow sources to load config. Introduce one new reusable workflow (`.github/workflows/notify.yml`) that dispatches to `telegram` or `slack` or no-op. Add one new agent workflow + prompt (`autoagent-planner.yml` + `planner.md`) that runs before the Implementer and either (i) triggers it directly for low/medium risk or (ii) opens a spec PR and pauses. No new runtime dependencies, no database, no Terraform.

**Tech Stack:** GitHub Actions, Bash, `gh`, `jq`, `envsubst`, `yq` (for parsing the new YAML config — added as a one-line install per job), `actionlint` (local dev only), Claude Code CLI (existing).

**Pre-read:** The engineer MUST read `ARCHITECTURE.md` at repo root before starting. It documents every workflow, prompt, and the state machine that this plan modifies. Every file:line citation below assumes `ARCHITECTURE.md` as context.

**Branch strategy:** Work on `main` in this spike repo. Commit after every task. Never force-push.

**How to read the code blocks in this plan:** Every shell snippet, YAML block, and prompt text below is a **reference implementation**, not copy-paste. Line numbers and file layouts shift as earlier tasks land — if a later task cites `line 275`, use `grep` to re-locate the target. If your own judgment disagrees with a snippet (missing error handling, a cleaner idiom, a pinned version that has moved on), trust your judgment and commit the reasoning. The plan encodes intent and contract, not literal text.

---

## Task decomposition (overview)

| # | Deliverable | Files |
|---|---|---|
| 0 | Baseline: prove the pipeline runs green before any refactor | (no files) |
| 1 | Config file schema + validation helper | `.github/autoagent-config.yml`, `.github/scripts/autoagent-config.sh`, `.github/scripts/test-autoagent-config.sh` |
| 2 | Pluggable notifications | `.github/workflows/notify.yml` (new), `telegram.yml` (deleted), every agent workflow (call-site update) |
| 3 | Wire config into Implementer + fix scheduled-model hardcode | `.github/workflows/autoagent-implementer.yml` |
| 4 | Wire config into Fixer, Merger, Board-Sync, Week-Rollover | the four YAML files |
| 5 | Implementer inner-loop: explicit test retry budget in prompt | `.github/prompts/implementer.md` |
| 6 | Planner prompt (change-set with YAML frontmatter) | `.github/prompts/planner.md` |
| 7 | Planner workflow + risk gate (frontmatter parsed with yq) | `.github/workflows/autoagent-planner.yml` |
| 8 | Wire Planner → Implementer: change-set via issue comment | `autoagent-implementer.yml` |
| 9 | Issue template for plannable work | `.github/ISSUE_TEMPLATE/plannable-feature.yml` |
| 10 | README rewrite + setup guide | `README.md` |
| 11 | End-to-end smoke test | manual dispatch on a seed issue |

Each task ends with a commit. Task 0 is the regression baseline; Tasks 1–5 make the existing pipeline more configurable and safer; Tasks 6–8 add the Planner; Tasks 9–11 polish and verify.

---

### Task 0: Baseline — prove the existing pipeline runs green

**Why:** Tasks 3 and 4 refactor working code across 4 YAML files. If something breaks later, we need to know it was green before we touched it. Every subsequent "it's broken" observation should be diffable against this baseline.

**Prerequisites:** a real GitHub repo (fork) with `AGENT_PAT`, `ANTHROPIC_API_KEY`, Projects V2 board, and at least one `Todo` issue with a priority label in the current week's milestone. The placeholder `your-org` values in the workflows must already be replaced with real ones (or the baseline run is meaningless).

- [ ] **Step 1: Confirm real config is set**

```bash
grep -n "your-org" .github/workflows/*.yml
```

Expected: zero matches. If any remain, set real values before proceeding — don't run the pipeline with placeholders.

- [ ] **Step 2: Dispatch the Implementer on a seed issue**

Pick a small, clearly low-risk issue (a docs typo is ideal) with number `$N`:

```bash
gh workflow run autoagent-implementer.yml \
  -f issue_number=$N \
  -f base_branch=main \
  -f model=claude-sonnet-4-6
gh run watch
```

- [ ] **Step 3: Record outcomes**

Write `docs/smoke-tests/2026-04-13-baseline.md` with:
- Issue URL
- Implementer run URL + exit status
- PR URL (if opened)
- Board transition observed (`Todo → In Progress → Ready For QA`)
- Notifications received (Telegram message bodies)

If the baseline fails, stop and diagnose before touching config — we're debugging upstream, not our own changes.

- [ ] **Step 4: Commit the baseline log**

```bash
git add docs/smoke-tests/2026-04-13-baseline.md
git commit -m "docs: baseline smoke-test of upstream pipeline before refactor"
```

---

### Task 1: Config file + loader + loader tests

**Why:** Every hardcoded `your-org`, `your-repo`, `PROJECT_NUMBER: 1`, board column name, model name, and `max-turns` value is duplicated across 4+ workflows. Centralising them is a prerequisite for every other task.

**Files:**
- Create: `.github/autoagent-config.yml`
- Create: `.github/scripts/autoagent-config.sh`
- Create: `.github/scripts/test-autoagent-config.sh`

- [ ] **Step 1: Draft the config schema**

Write `.github/autoagent-config.yml`:

```yaml
# .github/autoagent-config.yml
# Central configuration for all autoagent-* workflows.
# Every agent workflow sources .github/scripts/autoagent-config.sh which parses
# this file with yq and exports the values as environment variables.

github:
  organization: "your-org"          # org or user that owns the Projects V2 board
  repository: "your-org/your-repo"  # full OWNER/NAME
  project_number: 1                 # Projects V2 board number

board:
  status_field: "Status"
  columns:
    todo: "Todo"
    in_progress: "In Progress"
    ready_for_qa: "Ready For QA"
    done: "Done"

milestones:
  # Set use_iterations: true to ignore milestones and drive week rollover off a
  # ProjectV2IterationField instead.
  use_iterations: false
  format: "YY CW WW"                 # only used in milestones mode
  iteration_field: "Calendar Week"   # only used in iterations mode
  done_status: "Done"                # only used in iterations mode

labels:
  priorities: ["p0", "p1", "p2", "p3", "p4", "p5"]
  plan: "plan"       # Planner agent trigger label
  high_risk: "risk/high"
  medium_risk: "risk/medium"
  low_risk: "risk/low"

branch:
  prefix: "autoagent/"

severity_keywords:
  # Reviewer comments matching these keywords block the merger.
  blocking: ["CRITICAL", "MEDIUM"]

agents:
  planner:
    enabled: true
    model: "claude-sonnet-4-6"
    max_turns: 80
    timeout_minutes: 20
  implementer:
    enabled: true
    model: "claude-opus-4-6"
    max_turns: 500
    timeout_minutes: 90
    test_retry_budget: 3             # max times Claude may re-run failing tests
  fixer:
    enabled: true
    model: "claude-sonnet-4-6"
    max_turns: 500
    timeout_minutes: 60
  merger:
    enabled: true
    model: "claude-sonnet-4-6"
    merge_method: "merge"            # merge | squash | rebase
    pause_seconds: 10

notifications:
  provider: "telegram"               # telegram | slack | none
  telegram:
    bot_token_secret: "TELEGRAM_BOT_TOKEN"
    chat_id_secret: "TELEGRAM_CHAT_ID"
  slack:
    webhook_secret: "SLACK_WEBHOOK_URL"

runner:
  labels: "ubuntu-latest"            # passed verbatim to `runs-on:`
```

- [ ] **Step 2: Write the loader script**

Create `.github/scripts/autoagent-config.sh`. This script is **sourced** (not executed) so its `export`s land in the caller's shell. It must:
1. Locate the config file (default `.github/autoagent-config.yml`, overridable via `$AUTOAGENT_CONFIG`).
2. Assume `yq` is already on `PATH` — installed once per workflow via the `mikefarah/yq@v4` action (see Task 1 Step 6 below). Fail with a clear message if it isn't.
3. Export every flat value as `AUTOAGENT_*` env vars.
4. Fail fast with a clear error if required fields are missing or placeholder strings (`your-org`, `your-repo`) leak into production.

**Why not `sudo curl`-install `yq` inside the loader?** That pattern adds ~5s per job, depends on outbound network, and fails silently in hardened runners. The action is pinned, cached, and runs once per job.

```bash
#!/usr/bin/env bash
# .github/scripts/autoagent-config.sh
# Source (don't exec) to load config into the current shell:
#   source .github/scripts/autoagent-config.sh
#
# Required on PATH: bash>=4, curl (for yq install), jq.

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
export AUTOAGENT_SEVERITY_REGEX="$(yq -r '.severity_keywords.blocking | map("\\b"+.+"\\b") | join("|")' "$CONFIG_PATH")"

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
```

Make it executable: `chmod +x .github/scripts/autoagent-config.sh`.

- [ ] **Step 3: Write a tiny test harness**

Create `.github/scripts/test-autoagent-config.sh`:

```bash
#!/usr/bin/env bash
# .github/scripts/test-autoagent-config.sh
# Run locally: bash .github/scripts/test-autoagent-config.sh
# Uses a throwaway config to exercise the loader.

set -euo pipefail
cd "$(dirname "$0")/../.."

TMP=$(mktemp -d)
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

# Load it.
AUTOAGENT_CONFIG="$TMP/config.yml" source .github/scripts/autoagent-config.sh

# Assertions.
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
```

- [ ] **Step 4: Run the test**

Install `yq` locally first if you don't have it: `brew install yq` / `snap install yq` / `go install github.com/mikefarah/yq/v4@latest`. Then:

```bash
bash .github/scripts/test-autoagent-config.sh
```

Expected: `PASS: autoagent-config.sh loaded all expected keys`.

- [ ] **Step 5: Commit the loader + config**

```bash
git add .github/autoagent-config.yml .github/scripts/autoagent-config.sh .github/scripts/test-autoagent-config.sh
git commit -m "feat: add autoagent-config.yml and shared loader script"
```

- [ ] **Step 6: Add a tiny "install yq" composite workflow step (for later reuse)**

Rather than paste the same `uses: mikefarah/yq@v4.44.3` block into every workflow, create a composite action that every agent workflow will use in subsequent tasks:

Create `.github/actions/autoagent-setup/action.yml`:

```yaml
# .github/actions/autoagent-setup/action.yml
# Composite action: installs yq (pinned) and sources autoagent-config.sh,
# exporting AUTOAGENT_* env vars into the calling job.
#
# Usage in a job:
#   - uses: actions/checkout@v4
#   - uses: ./.github/actions/autoagent-setup

name: Autoagent setup
description: Install yq and load autoagent-config.yml into the job environment.

runs:
  using: composite
  steps:
    - name: Install yq
      uses: mikefarah/yq@v4.44.3

    - name: Load autoagent config
      shell: bash
      run: |
        source .github/scripts/autoagent-config.sh
        env | grep '^AUTOAGENT_' >> "$GITHUB_ENV"
```

Pin the yq action by SHA instead of tag in a follow-up hardening pass if your org requires it.

- [ ] **Step 7: Commit the composite action**

```bash
git add .github/actions/autoagent-setup/action.yml
git commit -m "feat: composite action that installs yq and loads autoagent config"
```

---

### Task 2: Pluggable notifications

**Why:** `telegram.yml` is a required reusable workflow — missing secrets fail every agent run. We want `provider: telegram | slack | none` in config and a single call-site for callers.

**Files:**
- Create: `.github/workflows/notify.yml`
- Delete: `.github/workflows/telegram.yml`
- Modify: every `uses: ./.github/workflows/telegram.yml` call-site (Implementer, Fixer, Merger; Board-Sync uses curl directly — convert that too)

- [ ] **Step 1: Write the new reusable workflow**

Create `.github/workflows/notify.yml`:

```yaml
# .github/workflows/notify.yml
# Reusable workflow that dispatches a notification to the configured provider.
# Called via: uses: ./.github/workflows/notify.yml

name: Notify

on:
  workflow_call:
    inputs:
      message:
        required: true
        type: string
    secrets:
      TELEGRAM_BOT_TOKEN: {required: false}
      TELEGRAM_CHAT_ID:   {required: false}
      SLACK_WEBHOOK_URL:  {required: false}

jobs:
  send:
    runs-on: ubuntu-latest
    timeout-minutes: 2
    steps:
      - uses: actions/checkout@v4
        with: {sparse-checkout: .github, sparse-checkout-cone-mode: false}

      - uses: ./.github/actions/autoagent-setup

      - name: Send (telegram)
        if: env.AUTOAGENT_NOTIFY_PROVIDER == 'telegram'
        env:
          MESSAGE: ${{ inputs.message }}
          BOT: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          CHAT: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          if [ -z "$BOT" ] || [ -z "$CHAT" ]; then
            echo "notify: telegram secrets missing — skipping"; exit 0
          fi
          curl -sS -X POST "https://api.telegram.org/bot${BOT}/sendMessage" \
            --data-urlencode "chat_id=${CHAT}" \
            --data-urlencode "text=${MESSAGE}" >/dev/null

      - name: Send (slack)
        if: env.AUTOAGENT_NOTIFY_PROVIDER == 'slack'
        env:
          MESSAGE: ${{ inputs.message }}
          WEBHOOK: ${{ secrets.SLACK_WEBHOOK_URL }}
        run: |
          if [ -z "$WEBHOOK" ]; then
            echo "notify: slack webhook missing — skipping"; exit 0
          fi
          jq -n --arg t "$MESSAGE" '{text:$t}' | curl -sS -X POST -H 'Content-Type: application/json' --data @- "$WEBHOOK" >/dev/null

      - name: Skip (none)
        if: env.AUTOAGENT_NOTIFY_PROVIDER == 'none'
        run: echo "notify: provider=none, skipping"
```

Key properties:
- Missing secrets degrade to a log line, never fail.
- `provider: none` short-circuits.
- Sparse checkout keeps the job fast (no full repo).

- [ ] **Step 2: Delete the old Telegram workflow**

```bash
git rm .github/workflows/telegram.yml
```

- [ ] **Step 3: Update every call-site**

In `autoagent-implementer.yml`, `autoagent-fixer.yml`, `autoagent-merger.yml`, replace:

```yaml
  uses: ./.github/workflows/telegram.yml
  with:
    message: ${{ needs.prepare.outputs.start_message }}
  secrets:
    TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
    TELEGRAM_CHAT_ID:   ${{ secrets.TELEGRAM_CHAT_ID }}
```

with:

```yaml
  uses: ./.github/workflows/notify.yml
  with:
    message: ${{ needs.prepare.outputs.start_message }}
  secrets:
    TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
    TELEGRAM_CHAT_ID:   ${{ secrets.TELEGRAM_CHAT_ID }}
    SLACK_WEBHOOK_URL:  ${{ secrets.SLACK_WEBHOOK_URL }}
```

In `autoagent-board-sync.yml`, replace the direct `curl` Telegram calls (lines near 100, 135, 180 — grep for `api.telegram.org` to find them) with `uses: ./.github/workflows/notify.yml` in a dedicated job, or extract a shared step. Simpler: inline the same provider-switch snippet as `notify.yml` since board-sync runs on a single job. Do the latter and cite the decision in the commit message.

- [ ] **Step 4: Validate workflow syntax**

If `actionlint` is installed locally:

```bash
actionlint .github/workflows/*.yml
```

Expected: no errors. If not installed: `gh workflow list` from the repo after push will show all 6 workflows parsed successfully.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/notify.yml .github/workflows/autoagent-*.yml
git rm .github/workflows/telegram.yml
git commit -m "feat: pluggable notifications via notify.yml (telegram|slack|none)"
```

---

### Task 3: Wire config into Implementer + fix scheduled-path model hardcode

**Why:** The Implementer has the most hardcoded values (§7 of ARCHITECTURE.md) and the scheduled-path model bug at line 275.

**Files:**
- Modify: `.github/workflows/autoagent-implementer.yml`

- [ ] **Step 1: Remove the `env:` block of hardcoded strings**

At the top of the workflow (lines ~30-36), delete:

```yaml
env:
  PROJECT_ORG: "your-org"
  REPO: "your-org/your-repo"
  PROJECT_NUMBER: 1
```

- [ ] **Step 2: Use the composite action to load config in every job**

In each job (`prepare`, `implement`), insert as the first step *after* `actions/checkout`:

```yaml
      - uses: ./.github/actions/autoagent-setup
```

That one line installs `yq` (via the pinned `mikefarah/yq` action) and exports every `AUTOAGENT_*` var into `$GITHUB_ENV` so later steps see them. No `sudo curl`, no per-step install.

- [ ] **Step 3: Replace every hardcoded reference**

Search and replace in `autoagent-implementer.yml`:

| Old | New |
|---|---|
| `"$PROJECT_ORG"` / `${{ env.PROJECT_ORG }}` | `"$AUTOAGENT_ORG"` |
| `"$REPO"` / `${{ env.REPO }}` | `"$AUTOAGENT_REPO"` |
| `'"$PROJECT_NUMBER"'` / `${{ env.PROJECT_NUMBER }}` | `'"$AUTOAGENT_PROJECT_NUMBER"'` |
| `"Todo"` (in GraphQL Status filters) | `"$AUTOAGENT_COL_TODO"` |
| `"In Progress"` (in the mutation option lookup) | `"$AUTOAGENT_COL_IN_PROGRESS"` |
| `"Status"` (field name in queries) | `"$AUTOAGENT_STATUS_FIELD"` |
| `autoagent/` prefix in safety checks | `"$AUTOAGENT_BRANCH_PREFIX"` |
| `--max-turns 500` | `--max-turns "$AUTOAGENT_IMPLEMENTER_MAX_TURNS"` |
| `timeout-minutes: 90` | `timeout-minutes: ${{ fromJSON(needs.prepare.outputs.timeout) }}` and export from prepare |

The timeout knob is the one place where you need an output — `timeout-minutes:` is evaluated before the job starts, so the value must come from a job-level output of `prepare`.

- [ ] **Step 4: Fix the scheduled-path model (ARCHITECTURE.md §9.1)**

Currently line ~275:

```yaml
echo "model=claude-opus-4-6" >> $GITHUB_OUTPUT
```

Replace with:

```yaml
echo "model=$AUTOAGENT_IMPLEMENTER_MODEL" >> $GITHUB_OUTPUT
```

The manual-dispatch path (lines 63-76) already honours the input — leave it alone.

- [ ] **Step 5: Read the prompt from the working tree, not origin/main (ARCHITECTURE.md §9.2)**

In the `implement` job, change:

```bash
git show origin/main:.github/prompts/implementer.md
```

to just:

```bash
cat .github/prompts/implementer.md
```

This makes PR iteration on the prompt actually testable.

- [ ] **Step 6: Dry-run validation**

Locally:

```bash
actionlint .github/workflows/autoagent-implementer.yml
```

Expected: no errors. Then in GitHub:

```bash
gh workflow run autoagent-implementer.yml -f issue_number=<SEED_ISSUE> -f base_branch=main -f model=claude-sonnet-4-6
```

Watch: `gh run watch`. Expected: prepare job exits with `skip=false` and moves the issue to `In Progress`. If it skips with a config error, fix before continuing.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/autoagent-implementer.yml
git commit -m "refactor: source autoagent-config in implementer, fix scheduled model, read prompt from worktree"
```

---

### Task 4: Wire config into Fixer, Merger, Board-Sync, Week-Rollover

**Why:** Same rationale as Task 3 for the other four workflows. Mechanical work but large (there are ~30 hardcoded references across these files — see ARCHITECTURE.md §6/§7).

**Files:**
- Modify: `.github/workflows/autoagent-fixer.yml`
- Modify: `.github/workflows/autoagent-merger.yml`
- Modify: `.github/workflows/autoagent-board-sync.yml`
- Modify: `.github/workflows/auto-week-rollover.yml`

- [ ] **Step 1: Apply the Task 3 pattern to the Fixer**

- Remove the top-level `env:` block.
- Add `Load autoagent config` as the first step of each job.
- Replace `"Ready For QA"` and `"Done"` column names (none in fixer — verify with grep).
- Replace `--max-turns 500` with `$AUTOAGENT_FIXER_MAX_TURNS`.
- Replace the severity keyword filter (grep for `CRITICAL|MEDIUM` in review comments, line ~81 of merger; fixer doesn't have it) — we'll update merger in Step 3 below.
- Read prompt from working tree (same `git show origin/main:` → `cat` substitution).
- Replace `autoagent/` branch prefix with `$AUTOAGENT_BRANCH_PREFIX`.

- [ ] **Step 2: Merger — replace the hardcoded severity keyword filter**

Line ~81 of `autoagent-merger.yml` uses a literal `grep -qE '\\bCRITICAL\\b|\\bMEDIUM\\b'`. Replace with `grep -qE "$AUTOAGENT_SEVERITY_REGEX"`.

Also replace `--merge` on the `gh pr merge` line with `--$AUTOAGENT_MERGER_METHOD`. Change the `sleep 10` to `sleep "$AUTOAGENT_MERGER_PAUSE"`.

- [ ] **Step 3: Board-Sync — replace ORG/NUMBER + fix pagination**

Apart from the mechanical replacements, ARCHITECTURE.md §9.4 calls out that `autoagent-board-sync.yml` fetches only the first 100 items. Port the cursor-pagination pattern already present in `autoagent-implementer.yml` (lines 85-150) into the board-sync GraphQL query. Bite-sized:

1. Wrap the existing query in a `while [ "$HAS_NEXT" = "true" ]` loop with `CURSOR`.
2. Add `pageInfo { hasNextPage endCursor }` to the response.
3. Accumulate matches into a temp file; break as soon as the issue number is found (since board-sync only needs that one).

If the fork doesn't intend to run boards with >100 items you can defer this to a follow-up issue — mark it `risk/low` so the Planner picks it up. Add a TODO comment in the workflow: `# TODO(autoagent-config): pagination if board grows beyond 100 items`.

- [ ] **Step 4: Week-Rollover — replace ORG/NUMBER + milestone format**

Same `env:` block removal. The `${YEAR} CW ${THIS_WEEK_NUM}` format is not directly configurable because `date` shell manipulation is involved; instead add a comment at the top noting that the format is `YY CW WW` and that editing it requires touching this file — and record that caveat in `autoagent-config.yml` as a comment next to `milestones.format`. Acceptable scope cut for MVP.

- [ ] **Step 5: Dry-run validation**

```bash
actionlint .github/workflows/*.yml
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/autoagent-fixer.yml .github/workflows/autoagent-merger.yml .github/workflows/autoagent-board-sync.yml .github/workflows/auto-week-rollover.yml
git commit -m "refactor: source autoagent-config in fixer/merger/board-sync/rollover"
```

---

### Task 5: Implementer inner-loop — explicit test retry budget

**Why:** ARCHITECTURE.md §9.3 + CLAUDE.md §2.4. Today the prompt says "run tests" but has no retry budget. We want: after each implementation change, run tests; if they fail, attempt up to `N` fix iterations before giving up and opening the PR as draft with a failing-tests notice.

**Files:**
- Modify: `.github/prompts/implementer.md`

- [ ] **Step 1: Add the retry-budget block to `implementer.md`**

Open `.github/prompts/implementer.md`. After the existing Step 4 ("Run the test suite and fix failures"), replace that step with:

```markdown
## Step 4: Inner test loop (MANDATORY)

You have a **retry budget of ${TEST_RETRY_BUDGET} iterations** to get the test suite green before opening the PR.

For each iteration:
1. Run the project's test command (infer it from `package.json`, `Makefile`, `pyproject.toml`, `Cargo.toml`, etc. — pick the most local one).
2. If all tests pass: break out of the loop and proceed to Step 5.
3. If any test fails:
   - Read the failure output (not just the summary — actual assertions, stack traces).
   - Fix the root cause (not the test, unless the test itself is wrong and you can justify it).
   - Commit the fix with a message like `fix(test): <what you fixed>`.
   - Decrement the retry counter.

If the retry budget is exhausted and tests still fail:
- Do NOT abandon the work. Open the PR anyway as a **draft** (`gh pr create --draft`).
- Begin the PR description with: `⚠️ Tests failing — see run log`.
- List the failing tests in the description under a `## Failing tests` heading.
- The Fixer agent will pick up the PR once it's opened. Your job is to hand it off with full context.
```

The `${TEST_RETRY_BUDGET}` placeholder will be filled by envsubst in the Implementer workflow. Update the envsubst call in `autoagent-implementer.yml` (currently `envsubst '$ISSUE_NUM $ISSUE_TITLE $ISSUE_BODY $BASE'`) to include `$TEST_RETRY_BUDGET` and export that var from the loaded config:

```bash
export TEST_RETRY_BUDGET="$AUTOAGENT_IMPLEMENTER_TEST_RETRY_BUDGET"
cat .github/prompts/implementer.md | envsubst '$ISSUE_NUM $ISSUE_TITLE $ISSUE_BODY $BASE $TEST_RETRY_BUDGET' > /tmp/prompt.md
```

- [ ] **Step 2: Verify envsubst substitution locally**

```bash
TEST_RETRY_BUDGET=3 ISSUE_NUM=99 ISSUE_TITLE="test" ISSUE_BODY="b" BASE=main \
  envsubst '$ISSUE_NUM $ISSUE_TITLE $ISSUE_BODY $BASE $TEST_RETRY_BUDGET' \
  < .github/prompts/implementer.md | grep -c 'retry budget of 3'
```

Expected: `1` (or more — the string appears once in the template).

- [ ] **Step 3: Commit**

```bash
git add .github/prompts/implementer.md .github/workflows/autoagent-implementer.yml
git commit -m "feat(implementer): explicit test retry budget with draft-PR fallback"
```

---

### Task 6: Planner prompt (change-set as a single artefact with YAML frontmatter)

**Why:** CLAUDE.md §2.1. Produce a change-set specification and a risk classification before any code is written.

**Design note:** The Planner emits **one artefact**: a markdown document that starts with a YAML frontmatter block carrying the machine-readable fields (`risk`, `issue`, `base`). The workflow parses the frontmatter with `yq` — robust against whitespace, stray output, explanatory prose, or the model forgetting a trailer line. For **low/medium** risk, the artefact is posted as an **issue comment** with a marker so the Implementer can find it later — nothing touches the repo. For **high** risk, the artefact is committed to `docs/change-sets/${N}.md` on a plan branch and a spec PR is opened; human reviewers merge to approve. Normal cadence leaves no files behind.

**Files:**
- Create: `.github/prompts/planner.md`

- [ ] **Step 1: Write the prompt**

Create `.github/prompts/planner.md`:

```markdown
# AI Factory — Planner

You are the Planner agent. You are reading an issue that was labelled `${PLAN_LABEL}` (or dispatched manually). Your job is **not to write code**. You produce a written change-set that a separate Implementer agent will execute next.

## Inputs

- Issue number: `#${ISSUE_NUM}`
- Issue title: `${ISSUE_TITLE}`
- Issue body:
  ```
  ${ISSUE_BODY}
  ```
- Base branch: `${BASE}`
- You are checked out at `${BASE}`. You may read any file, including `CLAUDE.md`, `README.md`, `ARCHITECTURE.md`, and anything under `src/`, `tests/`, `.github/`.

## What to produce

Write the change-set to `/tmp/change-set.md`. **Do not commit it to the repo** — the workflow will decide what to do with it based on the `risk` field you set.

The file MUST start with a YAML frontmatter block exactly matching this shape (the workflow parses it with `yq`):

```markdown
---
risk: low                   # one of: low, medium, high
issue: ${ISSUE_NUM}
base: ${BASE}
---

# Change-set for #${ISSUE_NUM} — ${ISSUE_TITLE}

## Scope
1-3 sentences stating what is in scope and what is explicitly out of scope.

## Files to touch
- Create: `path/to/new.py` — one-line rationale
- Modify: `path/to/existing.py` — one-line rationale
- Delete: `path/to/obsolete.py` — one-line rationale

## Public API / contract changes
Function signatures, HTTP endpoints, CLI flags, schema — before/after. Write `None` if nothing public changes.

## Test plan
New tests to add, existing tests that must still pass.

## Risk justification
1-2 sentences explaining why you picked `low` / `medium` / `high` against the rubric.

## Open questions
Anything the issue body doesn't answer. `None` is a valid answer.
```

## Risk rubric

Classify as **high** if the change touches any of:
- Database schema / migrations
- Authentication, authorization, or IAM
- Public API surface (any change — breaking or not)
- Infrastructure-as-code (Terraform, Docker, Kubernetes, the CI pipeline itself)
- New runtime dependencies (dev-only deps don't count)
- Credentials, secrets, or encryption

Classify as **medium** if the change introduces substantial new business logic, refactors code used by more than 3 call-sites, or adds a new first-class module.

Classify as **low** otherwise: bug fixes, docs, tests, copy changes, UI tweaks, internal renames, configuration values.

When in doubt between `low` and `medium`, pick `medium`. Between `medium` and `high`, pick `high`.

## Workflow

1. Read the issue body and any files it references.
2. Write the change-set to `/tmp/change-set.md` with the exact frontmatter shape above.
3. Stop. Do not create branches, do not commit, do not open PRs — the workflow handles downstream routing based on your `risk` field.

## Guardrails

- Do NOT write application code.
- Do NOT modify anything in the repo. The only file you produce is `/tmp/change-set.md`.
- Do NOT invent requirements the issue doesn't state — file them under "Open questions".
- The frontmatter is machine-parsed. Get the keys exactly right (`risk:`, `issue:`, `base:`), one per line, no quotes on the values, `---` delimiters.
```

- [ ] **Step 2: Unit-test the frontmatter parser locally**

```bash
cat > /tmp/sample-change-set.md <<'EOF'
---
risk: medium
issue: 42
base: main
---

# Change-set for #42 — demo
## Scope
whatever
EOF

yq --front-matter=extract '.risk' /tmp/sample-change-set.md
```

Expected: `medium`. Also try with extra whitespace and quoted values to satisfy yourself the parser is forgiving.

- [ ] **Step 3: Commit**

```bash
git add .github/prompts/planner.md
git commit -m "feat(planner): prompt emits change-set with YAML frontmatter"
```

---

### Task 7: Planner workflow + risk gate (frontmatter-driven)

**Why:** CLAUDE.md §2.1 + §2.2. Connect the prompt to the GitHub Actions plumbing.

**Files:**
- Create: `.github/workflows/autoagent-planner.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/autoagent-planner.yml`:

```yaml
# .github/workflows/autoagent-planner.yml
name: '[AUTOAGENT] Planner'

on:
  issues:
    types: [labeled]
  workflow_dispatch:
    inputs:
      issue_number: {required: true, type: string}
      base_branch:  {required: false, type: string, default: main}

concurrency:
  group: autoagent-planner-${{ github.event.issue.number || inputs.issue_number }}
  cancel-in-progress: false

permissions:
  contents: write
  issues: write
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    # Only run on `labeled` event if the label matches the configured plan label.
    # For workflow_dispatch, always run.
    if: |
      github.event_name == 'workflow_dispatch' ||
      github.event.label.name == 'plan'     # sanity default; real gate below re-checks against config

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.AGENT_PAT }}

      - uses: ./.github/actions/autoagent-setup

      - name: Gate on configured plan label
        if: github.event_name == 'issues'
        run: |
          if [ "${{ github.event.label.name }}" != "$AUTOAGENT_LABEL_PLAN" ]; then
            echo "Label '${{ github.event.label.name }}' != configured '$AUTOAGENT_LABEL_PLAN' — skipping"
            exit 0
          fi

      - name: Resolve inputs
        id: inputs
        env:
          GH_TOKEN: ${{ secrets.AGENT_PAT }}
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            ISSUE_NUM="${{ inputs.issue_number }}"
            BASE="${{ inputs.base_branch }}"
          else
            ISSUE_NUM="${{ github.event.issue.number }}"
            BASE="main"
          fi
          ISSUE_JSON=$(gh issue view "$ISSUE_NUM" --json title,body)
          ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
          ISSUE_BODY=$(echo  "$ISSUE_JSON" | jq -r '.body')
          {
            echo "issue_num=$ISSUE_NUM"
            echo "base=$BASE"
            echo "issue_title<<EOF";  echo "$ISSUE_TITLE";  echo "EOF"
            echo "issue_body<<EOF";   echo "$ISSUE_BODY";   echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Install Claude Code
        run: npm install -g @anthropic-ai/claude-code

      - name: Run Planner
        id: run
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GH_TOKEN: ${{ secrets.AGENT_PAT }}
          PLAN_LABEL: ${{ env.AUTOAGENT_LABEL_PLAN }}
          ISSUE_NUM:  ${{ steps.inputs.outputs.issue_num }}
          ISSUE_TITLE: ${{ steps.inputs.outputs.issue_title }}
          ISSUE_BODY:  ${{ steps.inputs.outputs.issue_body }}
          BASE:        ${{ steps.inputs.outputs.base }}
        run: |
          set -e
          cat .github/prompts/planner.md | \
            envsubst '$PLAN_LABEL $ISSUE_NUM $ISSUE_TITLE $ISSUE_BODY $BASE' \
            > /tmp/planner-prompt.md

          # Claude writes /tmp/change-set.md per the prompt contract.
          claude -p --model "$AUTOAGENT_PLANNER_MODEL" \
                 --max-turns "$AUTOAGENT_PLANNER_MAX_TURNS" \
                 --permission-mode auto \
                 --output-format text \
            < /tmp/planner-prompt.md

          if [ ! -s /tmp/change-set.md ]; then
            echo "planner: /tmp/change-set.md was not produced" >&2
            exit 1
          fi

          # Parse frontmatter.
          RISK=$(yq --front-matter=extract '.risk' /tmp/change-set.md)
          case "$RISK" in
            low|medium|high) ;;
            *) echo "planner: invalid risk in frontmatter: '$RISK'" >&2; exit 1 ;;
          esac

          echo "risk=$RISK" >> "$GITHUB_OUTPUT"

      - name: Label issue by risk, remove plan label
        env:
          GH_TOKEN: ${{ secrets.AGENT_PAT }}
          ISSUE_NUM: ${{ steps.inputs.outputs.issue_num }}
        run: |
          case "${{ steps.run.outputs.risk }}" in
            low)    LABEL="$AUTOAGENT_LABEL_LOW_RISK" ;;
            medium) LABEL="$AUTOAGENT_LABEL_MEDIUM_RISK" ;;
            high)   LABEL="$AUTOAGENT_LABEL_HIGH_RISK" ;;
          esac
          gh issue edit "$ISSUE_NUM" --add-label "$LABEL"
          gh issue edit "$ISSUE_NUM" --remove-label "$AUTOAGENT_LABEL_PLAN" || true

      - name: Low/medium-risk → post change-set as issue comment and dispatch Implementer
        if: steps.run.outputs.risk != 'high'
        env:
          GH_TOKEN: ${{ secrets.AGENT_PAT }}
          ISSUE_NUM: ${{ steps.inputs.outputs.issue_num }}
        run: |
          # Marker header lets the Implementer locate this comment later even if
          # other comments (from humans, from bots) arrive in between.
          {
            echo '<!-- AUTOAGENT_CHANGE_SET -->'
            cat /tmp/change-set.md
          } > /tmp/comment.md
          gh issue comment "$ISSUE_NUM" --body-file /tmp/comment.md

          gh workflow run autoagent-implementer.yml \
            -f issue_number="$ISSUE_NUM" \
            -f base_branch="${{ steps.inputs.outputs.base }}" \
            -f model="$AUTOAGENT_IMPLEMENTER_MODEL"

      - name: High-risk → commit change-set, open spec PR, PAUSE
        if: steps.run.outputs.risk == 'high'
        env:
          GH_TOKEN: ${{ secrets.AGENT_PAT }}
          ISSUE_NUM: ${{ steps.inputs.outputs.issue_num }}
          BASE:      ${{ steps.inputs.outputs.base }}
        run: |
          # Only high-risk leaves a file in the repo — and that file IS the PR diff,
          # which is the whole point. Low/medium never pollutes the filesystem.
          SLUG=$(echo "${{ steps.inputs.outputs.issue_title }}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
          BRANCH="${AUTOAGENT_BRANCH_PREFIX}plan-${ISSUE_NUM}-${SLUG}"

          git config user.name  "autoagent-planner"
          git config user.email "autoagent-planner@users.noreply.github.com"
          git checkout -b "$BRANCH" "origin/$BASE"
          mkdir -p docs/change-sets
          cp /tmp/change-set.md "docs/change-sets/${ISSUE_NUM}.md"
          git add "docs/change-sets/${ISSUE_NUM}.md"
          git commit -m "spec: change-set for #${ISSUE_NUM} [high-risk]"
          git push -u origin "$BRANCH"

          gh pr create \
            --base  "$BASE" \
            --head  "$BRANCH" \
            --title "spec: #${ISSUE_NUM} — ${{ steps.inputs.outputs.issue_title }} [high-risk]" \
            --body  "$(printf 'Change-set for #%s awaiting human review.\n\nRead `docs/change-sets/%s.md` in this diff. Merge this PR to approve the spec; then manually dispatch the Implementer with `base_branch=main` (or leave the listener wired up in a future task).' "$ISSUE_NUM" "$ISSUE_NUM")"

          # Pipeline PAUSES here. No Implementer dispatch for high-risk.
          echo "planner: high-risk change-set opened as spec PR — awaiting human approval" >&2

      - name: Notify
        if: always()
        uses: ./.github/workflows/notify.yml
        with:
          message: |
            [AUTOAGENT] Planner - #${{ steps.inputs.outputs.issue_num }}
            Risk: ${{ steps.run.outputs.risk || 'error' }}
            Spec: ${{ steps.run.outputs.spec_path || 'n/a' }}
        secrets:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID:   ${{ secrets.TELEGRAM_CHAT_ID }}
          SLACK_WEBHOOK_URL:  ${{ secrets.SLACK_WEBHOOK_URL }}
```

- [ ] **Step 2: Validate syntax**

```bash
actionlint .github/workflows/autoagent-planner.yml
```

Expected: no errors. Note: `uses: ./.github/workflows/notify.yml` inside a `step` (not `job`) will fail — GitHub only allows reusable workflows at the *job* level. Fix: split the notify into its own job (`notify`) that `needs: plan` and reads outputs. Update accordingly before committing.

- [ ] **Step 3: Refactor notify into its own job**

Replace the trailing step with a second job:

```yaml
  notify:
    needs: plan
    if: always()
    uses: ./.github/workflows/notify.yml
    with:
      message: "[AUTOAGENT] Planner - #${{ needs.plan.outputs.issue_num }} — risk=${{ needs.plan.outputs.risk }}"
    secrets:
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID:   ${{ secrets.TELEGRAM_CHAT_ID }}
      SLACK_WEBHOOK_URL:  ${{ secrets.SLACK_WEBHOOK_URL }}
```

Promote `issue_num` and `risk` to job-level outputs on the `plan` job:

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    outputs:
      issue_num: ${{ steps.inputs.outputs.issue_num }}
      risk:      ${{ steps.run.outputs.risk }}
    # ...
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/autoagent-planner.yml
git commit -m "feat(planner): workflow with risk gate and implementer dispatch"
```

---

### Task 8: Implementer reads the change-set (from issue comment or repo, no trailer parsing)

**Why:** The Planner's change-set should ground the Implementer's work — otherwise the Planner is decorative. The Implementer looks in two places, in order:
1. A committed `docs/change-sets/<N>.md` (only exists for high-risk work whose spec PR was merged).
2. The most recent issue comment with the `<!-- AUTOAGENT_CHANGE_SET -->` marker (low/medium path).

If neither is found, the Implementer falls back to the issue body — this preserves the pre-Planner workflow for anyone dispatching the Implementer directly.

**Files:**
- Modify: `.github/workflows/autoagent-implementer.yml`
- Modify: `.github/prompts/implementer.md`

- [ ] **Step 1: Fetch the change-set in the Implementer workflow**

In `autoagent-implementer.yml`, after the existing `Fetch issue details` step, add:

```yaml
      - name: Fetch change-set (if present)
        id: changeset
        env:
          GH_TOKEN: ${{ secrets.AGENT_PAT }}
          ISSUE_NUM: ${{ needs.prepare.outputs.issue_number }}
        run: |
          set -e
          CHANGE_SET=""

          # Priority 1: committed change-set (high-risk path after spec PR merged).
          if [ -f "docs/change-sets/${ISSUE_NUM}.md" ]; then
            CHANGE_SET=$(cat "docs/change-sets/${ISSUE_NUM}.md")
            echo "source=file:docs/change-sets/${ISSUE_NUM}.md" >> "$GITHUB_OUTPUT"
          else
            # Priority 2: latest issue comment with the AUTOAGENT_CHANGE_SET marker.
            LATEST=$(gh issue view "$ISSUE_NUM" --json comments \
              --jq '[.comments[] | select(.body | startswith("<!-- AUTOAGENT_CHANGE_SET -->"))] | last.body // ""')
            if [ -n "$LATEST" ]; then
              # Strip the marker line.
              CHANGE_SET=$(printf '%s\n' "$LATEST" | tail -n +2)
              echo "source=issue-comment" >> "$GITHUB_OUTPUT"
            else
              echo "source=none" >> "$GITHUB_OUTPUT"
            fi
          fi

          {
            echo "change_set<<AUTOAGENT_EOF"
            printf '%s\n' "$CHANGE_SET"
            echo "AUTOAGENT_EOF"
          } >> "$GITHUB_OUTPUT"
```

The `AUTOAGENT_EOF` heredoc marker is chosen to avoid collisions with anything the change-set itself might contain.

- [ ] **Step 2: Pipe the change-set into the prompt**

Extend the envsubst call in the `Implement with Claude` step:

```bash
export TEST_RETRY_BUDGET="$AUTOAGENT_IMPLEMENTER_TEST_RETRY_BUDGET"
export CHANGE_SET="${{ steps.changeset.outputs.change_set }}"
cat .github/prompts/implementer.md | \
  envsubst '$ISSUE_NUM $ISSUE_TITLE $ISSUE_BODY $BASE $TEST_RETRY_BUDGET $CHANGE_SET' \
  > /tmp/prompt.md
```

- [ ] **Step 3: Update the Implementer prompt to consume the change-set**

In `.github/prompts/implementer.md`, insert at the top of the "Inputs" section:

```markdown
## Change-set (from Planner, if any)

${CHANGE_SET}

If the block above is empty, no change-set was produced (either the Planner was skipped or this issue was dispatched directly). Fall back to the issue body as your spec. If the block is populated, treat it as authoritative: stay within its declared scope, respect the risk classification in its frontmatter, and do not invent work it doesn't list. The `## Files to touch` section is your shopping list — if you need to touch something outside it, stop and comment on the issue explaining why instead.
```

- [ ] **Step 4: Smoke-test the fetch locally**

Pick an issue with an `AUTOAGENT_CHANGE_SET` comment (created manually for this test) and verify:

```bash
gh issue view <N> --json comments \
  --jq '[.comments[] | select(.body | startswith("<!-- AUTOAGENT_CHANGE_SET -->"))] | last.body' \
  | head -20
```

Expected: the marker line followed by the frontmatter.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/autoagent-implementer.yml .github/prompts/implementer.md
git commit -m "feat(implementer): read change-set from issue comment or docs/change-sets/"
```

---

### Task 9: Issue template

**Files:**
- Create: `.github/ISSUE_TEMPLATE/plannable-feature.yml`

- [ ] **Step 1: Write the template**

```yaml
# .github/ISSUE_TEMPLATE/plannable-feature.yml
name: Plannable feature
description: Request a change that the AI Factory will plan, implement, and merge autonomously.
title: "<short imperative summary>"
labels: ["plan"]
body:
  - type: markdown
    attributes:
      value: |
        This issue will be picked up by the Planner agent. The Planner produces a change-set and classifies risk. High-risk changes open a spec PR for human review; low/medium-risk changes dispatch straight to the Implementer.
  - type: input
    id: priority
    attributes:
      label: Priority
      description: "p0 (blocker) … p5 (backlog). Add the matching label after filing."
      placeholder: "p2"
    validations: {required: true}
  - type: textarea
    id: context
    attributes:
      label: Context
      description: "Why does this matter? What broke or what's the opportunity?"
    validations: {required: true}
  - type: textarea
    id: desired_outcome
    attributes:
      label: Desired outcome
      description: "What does 'done' look like? Be concrete."
    validations: {required: true}
  - type: textarea
    id: non_goals
    attributes:
      label: Out of scope
      description: "Anything related that should NOT be included in this change-set."
  - type: textarea
    id: dependencies
    attributes:
      label: Dependencies
      description: "Use 'Depends on: #123' to base this work on another open PR. Multi-line allowed."
      placeholder: "Depends on: #123"
  - type: input
    id: acceptance
    attributes:
      label: Acceptance test
      description: "The single observable behaviour that proves this shipped."
    validations: {required: true}
```

- [ ] **Step 2: Commit**

```bash
git add .github/ISSUE_TEMPLATE/plannable-feature.yml
git commit -m "docs: add plannable-feature issue template"
```

---

### Task 10: README rewrite

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the README**

Replace the shipped (18 KB) README with a structure that reflects the new state. Required sections, in order:

1. **What is this** — one paragraph, what the pipeline does end-to-end.
2. **Agents** — Planner, Implementer, Fixer, Merger. One paragraph each, citing the workflow file and prompt file for each.
3. **State machine** — re-use the ASCII diagram from `ARCHITECTURE.md` §2.
4. **Risk gate** — explain the `low`/`medium`/`high` rubric and what happens at each level. Link to `planner.md`.
5. **Setup**
   - Required secrets: `ANTHROPIC_API_KEY`, `AGENT_PAT` (scopes: repo, project, workflow), optional `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` or `SLACK_WEBHOOK_URL`.
   - Required labels: priority (`p0`..`p5`), risk (`risk/low`, `risk/medium`, `risk/high`), plan trigger (`plan`).
   - Required Projects V2 board: with columns `Todo / In Progress / Ready For QA / Done` (rename in `autoagent-config.yml` if yours differ).
   - Configuration: edit `.github/autoagent-config.yml` — walk through every top-level key.
   - Runner: Linux (`ubuntu-latest`) default; self-hosted works if it has `node`, `npm`, `gh`, `jq`, `git`, `curl`.
6. **Your first run** — step-by-step:
   - Create an issue from the `Plannable feature` template.
   - Add the `plan` label.
   - Watch Actions → `[AUTOAGENT] Planner` fire.
   - For low/medium: Implementer dispatches automatically.
   - For high: review the spec PR; merge to approve; manually dispatch the Implementer.
7. **Differences from upstream** — bullet list:
   - Added Planner agent (risk-classifying spec producer; low/medium posts change-set as issue comment, high opens a spec PR and pauses).
   - Change-set is a markdown file with YAML frontmatter, parsed with `yq` — no fragile stdout trailer.
   - Added `.github/autoagent-config.yml` + loader + `.github/actions/autoagent-setup` composite action.
   - Pluggable notifications (telegram | slack | none).
   - Explicit test retry budget in Implementer with draft-PR fallback.
   - Board-sync pagination (if completed in Task 4).
   - Fixed: scheduled-path Implementer model now honours config.
   - Fixed: Implementer/Fixer prompts now read from working tree, not `origin/main`.
8. **Relationship to Claude Managed Agents** — preserve the section from the current README (see commit `42349e4` — keep as-is).
9. **Troubleshooting** — the top 5 "why didn't my agent run" scenarios: plan label not matched, placeholder config values, missing `AGENT_PAT` scopes, board column name mismatch, Claude API quota.

Aim for 500–800 lines of Markdown. No emoji unless the current README has them.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for AI Factory MVP (planner, config, pluggable notifications)"
```

---

### Task 11: End-to-end smoke test

**Why:** Evidence before assertions. Every prior task had a narrow verification; this one exercises the whole pipeline.

- [ ] **Step 1: Create a seed issue using the new template**

In the GitHub UI (or via `gh issue create --template plannable-feature.yml`), file a deliberately low-risk issue like "docs: add a `Getting started` subsection to README". Do NOT add the `plan` label yet.

- [ ] **Step 2: Add the `plan` label**

```bash
gh issue edit <N> --add-label plan
```

Expected: `[AUTOAGENT] Planner` workflow fires within seconds.

- [ ] **Step 3: Watch the Planner run**

```bash
gh run watch
```

Expected terminal output:
- `planner: installing yq ...` (or already installed)
- `autoagent-config: loaded (org=... repo=... project=... provider=...)`
- Claude produces the change-set and trailer.
- Trailer parsed, `risk/low` label added, `plan` label removed.
- Implementer dispatched.

- [ ] **Step 4: Watch the Implementer run**

```bash
gh run list --workflow=autoagent-implementer.yml --limit 1
gh run watch <run-id>
```

Expected:
- Config loads cleanly.
- Change-set is read from `docs/change-sets/<N>-change-set.md`.
- Claude opens a PR branched from the planner branch (not `main`).
- `Closes #<N>` appears in the PR body.

- [ ] **Step 5: Let it flow through**

If CI is green, the Merger will pick it up on the next run (or dispatch manually: `gh workflow run autoagent-merger.yml`). The Board-Sync workflow moves the issue to `Done` on merge.

- [ ] **Step 6: Capture the result**

Write a brief smoke-test log into `docs/smoke-tests/2026-04-13-first-run.md` with:
- Issue URL
- Planner run URL + risk verdict
- Implementer run URL + PR URL
- Merger run URL (if reached)
- Total wall-clock time
- Any surprises

- [ ] **Step 7: Commit the log and close out**

```bash
git add docs/smoke-tests/2026-04-13-first-run.md
git commit -m "docs: smoke-test log for first AI Factory end-to-end run"
```

---

## Self-review (done)

- **Spec coverage** — CLAUDE.md 2.1 → Tasks 6-8. 2.2 → Task 7 (risk gate + label). 2.3 → Tasks 1-4 (config) + Task 2 (pluggable notifications). 2.4 → Task 5. 2.5 → Tasks 9-10. Deliverable #1 (ARCHITECTURE.md) produced separately (complete). ✓
- **No placeholders** — every task ships real shell, real YAML, real prompt text. The only intentional deferral is the milestone-format comment in Task 4 Step 4, which is called out explicitly as an MVP scope cut. ✓
- **Type consistency** — config key names (`AUTOAGENT_*`) are consistent across loader, tests, and every workflow consumer. Risk labels (`risk/high`, etc.) are used identically in Planner workflow, config, README, and prompt. ✓
- **Robustness fixes from review round 2** — (a) Planner output parsed from YAML frontmatter via `yq`, no exact-format stdout trailer; (b) `yq` installed once per job via a pinned composite action, not `sudo curl` per step; (c) low/medium change-sets live as issue comments with a marker, not committed files — zero repo pollution for normal cadence; (d) Task 0 establishes a baseline smoke-test before touching working code; (e) code blocks declared reference-only at the top of the plan. ✓

---

## Execution handoff

Two options:

1. **Subagent-driven** — a fresh subagent per task with two-stage review between each. Recommended for a plan this size so we can catch wrong turns early.
2. **Inline execution** — execute tasks in this session via the `executing-plans` skill, batched with checkpoints.

Pick one and reply with it.
