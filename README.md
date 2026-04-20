# AI Factory

An autonomous issue-to-merged-code pipeline built on GitHub Actions and the
Claude Code CLI. Four agents -- Planner, Implementer, Fixer, Merger -- pick
issues from a GitHub Projects V2 board, produce a risk-classified change-set,
implement it, fix their own CI failures, and merge green PRs, all without human
intervention. The only runtime dependencies are `gh`, `jq`, `yq`, and `curl`.
High-risk changes pause the pipeline for human approval; everything else flows
through automatically.

## Agents

### Planner

Triggered when the `plan` label is added to an issue (or via `workflow_dispatch`).
Reads the issue, the repo context (`CLAUDE.md`, `ARCHITECTURE.md`, manifests),
and produces a change-set document with YAML frontmatter specifying scope, files
to touch, API contract changes, a test plan, and a risk classification. The
workflow routes the change-set based on risk: low/medium posts it as an issue
comment and dispatches the Implementer automatically; high commits it to
`docs/change-sets/<N>.md` and opens a spec PR that pauses the pipeline until a
human approves.

- Workflow: `.github/workflows/autoagent-planner.yml`
- Prompt: `.github/prompts/planner.md`

### Implementer

Picks the highest-priority `Todo` issue from the current milestone on the
Projects V2 board, moves it to `In Progress`, creates a branch, hands the issue
to Claude Code for autonomous implementation, runs tests (with a configurable
retry budget), and opens a PR. Also accepts `workflow_dispatch` from the Planner
for direct dispatch.

- Workflow: `.github/workflows/autoagent-implementer.yml`
- Prompt: `.github/prompts/implementer.md`

### Fixer

Fires on CI failures, review comments, or merge conflicts on `autoagent/*`
branches. Gathers all failure context (run logs, inline review comments, review
verdicts, mergeable status), feeds it to Claude, and pushes fixes. Deduplicates
against other in-progress fixer runs so no PR is worked on twice.

- Workflow: `.github/workflows/autoagent-fixer.yml`
- Prompt: `.github/prompts/fixer.md`

### Merger

Scans for `autoagent/*` PRs where all checks pass, no changes are requested, no
unresolved `CRITICAL`/`MEDIUM` issues exist, and no merge conflicts remain.
Before merging, Claude reviews recent commits against review comments and returns
a `MERGE` or `SKIP` verdict. PRs are merged sequentially, with re-verification
between each merge.

- Workflow: `.github/workflows/autoagent-merger.yml`
- Prompt: `.github/prompts/merger.md`

Two support workflows keep the board and calendar consistent:

| Workflow | Purpose |
|---|---|
| `autoagent-board-sync.yml` | Moves the issue between Projects V2 columns on PR events |
| `auto-week-rollover.yml` | Creates this week's milestone/iteration, rolls unfinished work forward |

Notifications are handled by the reusable workflow `notify.yml`, which
dispatches to the configured provider (Telegram, Slack, or none).

## State machine

All state is expressed as Projects V2 `Status` column transitions driven by
branch name conventions and PR events.

```
                       +-----------+
       (issue created) |   Todo    |<-------------------------+
                       +-----+-----+                          |
                             |                                |
           Implementer picks | (priority + milestone filter)  | PR closed
           top issue, moves  v                                | without merge
                       +-----------+                          |
                       |In Progress|                          |
                       +-----+-----+                          |
                             |                                |
                Claude pushes| branch `autoagent/<num>-<slug>`|
                and opens PR v                                |
                       +-----------+                          |
                       |Ready For QA|-------------------------+
                       +-----+-----+
                             |
         All checks pass,    |  (Fixer loops here on failures,
         no CHANGES_REQUESTED|   no board transitions during fixes)
         & Claude gate says  v
         MERGE               |
                       +-----------+
                       |   Done    |
                       +-----------+
```

- **Todo -> In Progress**: `autoagent-implementer.yml` (prepare job) when it picks the issue.
- **In Progress -> Ready For QA**: `autoagent-board-sync.yml` on `pull_request.opened`, keyed off branch prefix `autoagent/<issue_num>-`.
- **Ready For QA -> Done**: `autoagent-board-sync.yml` on `pull_request.closed && merged`.
- **-> Todo (back)**: `autoagent-board-sync.yml` on `pull_request.closed && !merged`.

Column names are case-sensitive string matches in GraphQL responses.

## Risk gate

The Planner classifies every change-set into one of three risk tiers using the
rubric defined in `.github/prompts/planner.md`:

### High risk

Triggers: database schema/migrations, authentication/authorization/IAM, public
API surface changes, infrastructure-as-code (Terraform, Docker, Kubernetes, CI
pipeline core control flow), new runtime dependencies, credentials/secrets/
encryption.

Action: the Planner commits the change-set to `docs/change-sets/<N>.md` on a
dedicated branch, opens a spec PR for human review, and the pipeline pauses.
The Implementer is **not** dispatched. A human must review the spec PR, merge it
to approve the plan, and then manually trigger the Implementer via
`workflow_dispatch`.

### Medium risk

Triggers: substantial new business logic, refactor touching more than 3
call-sites, new first-class module.

Action: the Planner posts the change-set as an issue comment (prefixed with the
sentinel `<!-- AUTOAGENT_CHANGE_SET -->`), applies the `risk/medium` label, and
dispatches the Implementer automatically.

### Low risk

Triggers: bug fixes, docs, tests, copy changes, UI tweaks, internal renames,
configuration values.

Action: same as medium -- issue comment plus automatic Implementer dispatch,
with a `risk/low` label.

Tie-break rules: low vs. medium -> pick medium; medium vs. high -> pick high.

**Carve-out for this repository:** editing agent prompts under `.github/prompts/`
or non-critical helper workflows is classified as `medium`, not `high`. Reserve
`high` for changes to the triggering, permissions, or core control flow of the
four agent workflows.

## Setup

### Required secrets

Add these to your repository (Settings -> Secrets and variables -> Actions):

| Secret | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Anthropic API key for Claude Code CLI. |
| `AGENT_PAT` | Yes | GitHub Personal Access Token with `repo`, `project`, and `workflow` scopes. The default `GITHUB_TOKEN` cannot access org-level Projects V2; a PAT with `project` scope is required. |
| `TELEGRAM_BOT_TOKEN` | No | Telegram Bot API token (from @BotFather). Only needed if `notifications.provider` is `telegram`. |
| `TELEGRAM_CHAT_ID` | No | Telegram chat ID for notifications. Only needed if `notifications.provider` is `telegram`. |
| `SLACK_WEBHOOK_URL` | No | Slack incoming webhook URL. Only needed if `notifications.provider` is `slack`. |

### Required labels

Create these labels on your repository:

**Priority labels** (used by the Implementer to rank issues):

- `p0` -- Critical / blocker
- `p1` -- High priority
- `p2` -- Normal priority
- `p3` -- Medium priority
- `p4` -- Low priority
- `p5` -- Backlog

**Risk tier labels** (applied by the Planner after classification):

- `risk/low`
- `risk/medium`
- `risk/high`

**Plan trigger label**:

- `plan` -- Adding this label to an issue fires the Planner workflow.

All label names are configurable in `.github/autoagent-config.yml`.

### Required Projects V2 board

Create a GitHub Projects V2 board with these columns (names must match exactly;
they are case-sensitive):

- **Todo** -- Issues ready for implementation.
- **In Progress** -- Currently being worked on by an agent.
- **Ready For QA** -- PR opened, awaiting review/CI.
- **Done** -- Merged.

Column names are configurable in `autoagent-config.yml` under `board.columns`.

### Configuration

All project-specific values live in `.github/autoagent-config.yml`. The config
loader (`.github/scripts/autoagent-config.sh`) parses this file with `yq` and
exports `AUTOAGENT_*` environment variables. Every agent workflow loads the
config via the `.github/actions/autoagent-setup` composite action.

The loader validates that all required keys are present and non-null, and
refuses to run in CI if placeholder values like `your-org` are still in place.

Below is a walkthrough of every top-level key.

#### `github`

```yaml
github:
  organization: "herbae-org"        # org or user that owns the Projects V2 board
  repository: "herbae-org/foreman"  # full OWNER/NAME
  project_number: 2                 # Projects V2 board number
```

#### `board`

```yaml
board:
  status_field: "Status"            # name of the single-select status field
  columns:
    todo: "Todo"
    in_progress: "In Progress"
    ready_for_qa: "Ready For QA"
    done: "Done"
```

#### `milestones`

```yaml
milestones:
  use_iterations: false             # true to use iteration fields instead of milestones
  format: "YY CW WW"               # milestone title format (milestones mode only)
  iteration_field: "Calendar Week"  # iteration field name (iterations mode only)
  done_status: "Done"               # done column for iteration queries
```

#### `labels`

```yaml
labels:
  priorities: ["p0", "p1", "p2", "p3", "p4", "p5"]
  plan: "plan"                      # label that triggers the Planner
  high_risk: "risk/high"
  medium_risk: "risk/medium"
  low_risk: "risk/low"
```

#### `branch`

```yaml
branch:
  prefix: "autoagent/"              # all agent branches start with this prefix
```

Board Sync uses this prefix to map branches back to issues.

#### `severity_keywords`

```yaml
severity_keywords:
  blocking: ["CRITICAL", "MEDIUM"]  # reviewer comments matching these block the Merger
```

#### `agents`

```yaml
agents:
  planner:
    enabled: true
    model: "claude-sonnet-4-6"
    max_turns: 80
    timeout_minutes: 30
  implementer:
    enabled: true
    model: "claude-opus-4-6"
    max_turns: 500
    timeout_minutes: 90
    test_retry_budget: 3            # max times Claude may re-run failing tests
  fixer:
    enabled: true
    model: "claude-sonnet-4-6"
    max_turns: 500
    timeout_minutes: 60
  merger:
    enabled: true
    model: "claude-sonnet-4-6"
    merge_method: "merge"           # merge | squash | rebase
    pause_seconds: 10               # delay between sequential merges
```

#### `notifications`

```yaml
notifications:
  provider: "none"                  # telegram | slack | none
  telegram:
    bot_token_secret: "TELEGRAM_BOT_TOKEN"
    chat_id_secret: "TELEGRAM_CHAT_ID"
  slack:
    webhook_secret: "SLACK_WEBHOOK_URL"
```

Set `provider` to `telegram` or `slack` to enable notifications. Set it to
`none` to disable them entirely. The reusable `notify.yml` workflow reads
this value and dispatches accordingly. Missing secrets for the chosen provider
degrade to a log line, not a hard failure.

#### `runner`

```yaml
runner:
  labels: "ubuntu-latest"           # passed verbatim to runs-on:
```

### Runner requirements

The default runner is `ubuntu-latest`. Self-hosted runners work if they have:

- `node` and `npm` (for installing Claude Code CLI)
- `gh` (GitHub CLI)
- `jq`
- `git`
- `curl`
- `envsubst` (part of `gettext` on most Linux distributions)
- `yq` (v4.x; used by the config loader)
- `shellcheck` (only needed by the CI lint gate, not by the agents themselves)

## Your first run

1. **Create an issue** from the `Plannable feature` template
   (`.github/ISSUE_TEMPLATE/plannable-feature.yml`). Fill in the priority,
   context, desired outcome, and acceptance test fields.

2. **Add the `plan` label** (if the template did not already add it). This
   fires the Planner workflow.

3. **Watch GitHub Actions** -> `[AUTOAGENT] Planner`. The Planner reads the
   issue, reads the repo, and produces a change-set with a risk classification.

4. **For low/medium risk**: the Planner posts the change-set as an issue
   comment, labels the issue with the risk tier, removes the `plan` label,
   and dispatches the Implementer automatically. No human action needed.

5. **For high risk**: the Planner commits the change-set to
   `docs/change-sets/<N>.md` on a new branch, opens a spec PR, and pauses
   the pipeline. To proceed:
   - Review the spec PR.
   - Merge it to approve the plan.
   - Manually dispatch the Implementer workflow via `workflow_dispatch`,
     passing the issue number and base branch.

6. **Watch the Implementer** run. It creates an `autoagent/<N>-<slug>` branch,
   implements the change, runs tests (retrying up to the configured
   `test_retry_budget`), and opens a PR with `Closes #<N>`.

7. **If CI fails**, the Fixer picks up the PR on its next cycle (or on the
   `check_suite` event), gathers failure context, and pushes fixes.

8. **When all checks pass** and no blocking review issues remain, the Merger
   merges the PR and Board Sync moves the issue to Done.

## Differences from upstream

This repository is forked from
[leonardocardoso/three-body-agent](https://github.com/LeonardoCardoso/three-body-agent).
The following changes have been made:

- Added **Planner agent** (`autoagent-planner.yml` + `planner.md`): a
  risk-classifying spec producer. Low/medium risk posts the change-set as an
  issue comment and dispatches the Implementer; high risk opens a spec PR and
  pauses the pipeline for human approval.

- **Change-set is a markdown file with YAML frontmatter**, parsed with `yq`.
  No fragile stdout trailer.

- Added **`.github/autoagent-config.yml`** + loader
  (`.github/scripts/autoagent-config.sh`) + **`.github/actions/autoagent-setup`**
  composite action. All project-specific values (org, repo, board columns,
  labels, models, timeouts, notification provider) are centralised in a single
  config file and validated at load time.

- **Pluggable notifications** (`provider: telegram | slack | none` in config).
  The reusable `notify.yml` workflow dispatches to the configured provider.
  Missing secrets degrade gracefully instead of failing the pipeline.

- **Explicit test retry budget** in the Implementer prompt
  (`agents.implementer.test_retry_budget` in config) with a draft-PR fallback
  when the budget is exhausted.

- **Board-sync now paginates the GraphQL query** (handles boards with more
  than 100 items).

- **Fixed: scheduled-path Implementer model reads from config** instead of
  being hardcoded.

- **Fixed: Implementer/Fixer prompts read from the working tree**, not from
  `origin/main`.

- **Fixed: Implementer's `gh pr create` now has `GH_TOKEN: AGENT_PAT`
  exposed**, so PRs can trigger downstream workflows.

- **Fixed: `Todo -> In Progress` transition now fires on every trigger path**,
  not just the scheduled one.

- **Actionlint + shellcheck CI gate** (`test-workflows-lint.yml`) on every
  workflow change.

## How This Relates to Claude Managed Agents

Anthropic launched [Claude Managed Agents](https://www.anthropic.com/products/managed-agents) on the same day this project was released. The overlap is real - and intentional validation that autonomous development pipelines are the next frontier.

**What Managed Agents provides:** Cloud-hosted Claude sessions on a schedule, sandboxed execution, session persistence, and GitHub access via MCP tools. It solves the infrastructure problem - _how do I run Claude autonomously?_

**What Three-Body Agent provides:** The orchestration logic that turns autonomous Claude sessions into a functioning development team. Priority-based issue selection, dependency detection, sequential merge strategy, conflict-aware fixing, board state management, sprint automation, and multi-agent coordination with deduplication and concurrency controls.

Think of it this way: Managed Agents is the engine. Three-Body Agent is the self-driving car.

You can run this pipeline on GitHub Actions (as shipped), or adapt the workflow logic to run on Managed Agents infrastructure. The shell scripts, GraphQL queries, and prompt templates are the actual value - they work regardless of where Claude runs.

## Troubleshooting

### `plan` label not matched

The Planner workflow fires on every `issues.labeled` event, then checks whether
the label name matches `labels.plan` in `.github/autoagent-config.yml` (default:
`plan`). If your label is named differently (e.g. `Plan`, `autoagent:plan`),
update the config to match. The comparison is exact and case-sensitive.

### Placeholder values still in config

The config loader (`.github/scripts/autoagent-config.sh`) refuses to run in CI
if `github.organization` is still set to `your-org` or any `your-*` pattern.
You will see a loud failure in the Actions log:

```
autoagent-config: .github.organization is still 'your-org' -- set it in .github/autoagent-config.yml
```

Replace all placeholder values with your actual org and repo names.

### Missing `AGENT_PAT` scopes

The `AGENT_PAT` token needs three scopes: `repo`, `project`, and `workflow`.
The most common mistake is omitting `project` -- without it, every GraphQL
mutation against the Projects V2 board will fail silently or return permission
errors. If the Implementer picks an issue but never moves it to `In Progress`,
check the PAT scopes first.

### Board column name mismatch

Column names in `board.columns` must match your Projects V2 board exactly,
including case. `"Ready for QA"` is not the same as `"Ready For QA"`. The
GraphQL queries compare option labels as literal strings. If the Implementer
or Board Sync logs show `option not found`, compare the config values against
your board's column names character by character.

### Claude API quota exhaustion

If the Claude API returns rate-limit or quota errors, the agent's Claude Code
CLI session will fail and the workflow step will exit non-zero. Check the
Actions run log for `429` or `overloaded` errors. The Fixer will not help here
-- it fixes code failures, not infrastructure failures. Wait for quota to
replenish or upgrade your Anthropic plan.

## License

MIT
