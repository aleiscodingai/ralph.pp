# Ralph++

A resilient task runner that orchestrates [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to execute user stories from a PRD file — with per-task retries, crash-safe state, and a terminal UI for progress tracking.

Ralph++ reads a structured PRD (as JSON or Markdown), splits it into user stories sorted by priority, and feeds each one to Claude Code as an autonomous coding agent. If a story fails, it retries with context about what went wrong. When it's done, your PRD is updated in place with pass/fail status.

## Requirements

- **bash** 4+
- **[jq](https://jqlang.github.io/jq/)** for JSON processing
- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** (`claude` command)
- **bc** for cost calculations
- **git** (only required with `--diag-learn`)

## Quick Start

```bash
# Run with a JSON PRD
./ralph++.sh --prd my-feature.json

# Run with a Markdown PRD (auto-converts to JSON)
./ralph++.sh --prd my-feature.md

# Resume after a crash or partial failure
./ralph++.sh --prd my-feature.json --resume

# Preview the prompts without calling Claude
./ralph++.sh --prd my-feature.json --dry-run
```

## PRD Format

### JSON

```json
{
  "project": "my-app",
  "branchName": "ralph/my-feature",
  "description": "Add user authentication",
  "config": {
    "maxRetries": 5,
    "timeoutSeconds": 300,
    "maxTurns": 30
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Add login form",
      "description": "Create a login form with email and password fields",
      "acceptanceCriteria": [
        "Form has email input with validation",
        "Form has password input",
        "Submit button triggers auth flow",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

The `config` block is optional — values fall back to CLI flags, then environment variables, then defaults.

### Markdown

Pass a `.md` file and Ralph++ will auto-convert it to JSON using the `/ralph` slash command prompt (`~/.claude/commands/ralph.md`). The generated `.prd.json` is cached next to the source file and reused if the Markdown hasn't changed.

```bash
./ralph++.sh --prd feature-spec.md
# Creates feature-spec.prd.json, then runs it
```

## CLI Reference

```
Usage: ./ralph++.sh [OPTIONS]

Options:
  --prd FILE       Path to the PRD file (default: ./prd.json)
                   Accepts .json directly or .md (auto-converts via /ralph)
  --resume         Resume a previous run, retrying pending/failed stories
  --dry-run        Generate prompts without calling Claude
  --retries N      Max retry attempts per story (default: 10)
  --timeout SEC    Timeout in seconds per Claude call (default: 600)
  --max-turns N    Max agentic turns per Claude call (default: 50)
  --cost           Show per-story and total cost in the status table
  --diag-learn     On failure: capture git diff and run a diagnosis call,
                   then inject both into the retry prompt so the next
                   attempt learns from what was tried
  -h, --help       Show this help message
```

### Environment Variables

Override defaults without CLI flags:

| Variable | Default | Description |
|---|---|---|
| `RALPH_MAX_RETRIES` | `10` | Max retry attempts per story |
| `RALPH_TIMEOUT` | `600` | Timeout in seconds per Claude call |
| `RALPH_MAX_TURNS` | `50` | Max agentic turns per Claude call |

**Precedence:** CLI flags > `prd.json` config block > environment variables > defaults.

## How It Works

### Execution Flow

1. **Parse PRD** — reads stories, sorts by priority
2. **Initialize state** — creates a crash-safe JSON state file (or resumes from an existing one)
3. **Execute stories** — feeds each story to `claude --print` as a self-contained prompt with title, description, and acceptance criteria
4. **Handle failures** — on failure, retries with error context; moves to the next story if retries are exhausted
5. **Update PRD** — sets `passes` and `notes` on each story in place
6. **Report** — prints a summary table with pass/fail, duration, and token usage

### Retry Behavior

When a story fails (timeout, max turns, or Claude error), Ralph++ retries it up to `--retries` times.

**Default mode:** retries include the raw error reason so Claude knows *what* failed.

**With `--diag-learn`:** retries include a `git diff` of what the previous attempt changed plus an AI-generated diagnosis of why it failed. This gives Claude factual context about what was tried — rather than starting blind — while keeping the prompt focused on only the most recent attempt (no accumulated history bloat).

### Crash Safety

- State is persisted to `ralph++/.ralph-state-<project>.json` after every field change using atomic `mktemp` + `mv` writes
- On `--resume`, any tasks stuck in `running` status are reset to `pending`
- Stories already marked `passes: true` in the PRD are skipped automatically

### Branch Archival

When the `branchName` in your PRD changes between runs, the previous state file and logs are archived to `ralph++/archive/<date>-<branch>/` before starting fresh.

## Output Structure

All artifacts are created under `ralph++/` next to the PRD file:

```
ralph++/
  .ralph-state-<project>.json   # Crash-safe run state
  .last-branch                  # Tracks branch changes for archival
  logs/
    US-001/
      attempt-1.prompt.md       # Exact prompt sent to Claude
      attempt-1.out.json        # Raw Claude JSON response
      attempt-1.result.txt      # Extracted result text
      attempt-1.failure.log     # Failure details + diagnosis (on error)
      attempt-1.diff            # Git diff of changes (with --diag-learn)
  archive/
    2025-01-15-feature-name/    # Archived state + logs from previous runs
```

## License

MIT
