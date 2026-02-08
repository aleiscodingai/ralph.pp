#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Ralph Wiggum — Resilient Claude Code Task Runner               ║
# ║  Usage: ./ralph.sh [--prd prd.json] [--resume] [--dry-run]     ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Reads your existing prd.json format natively:
#   { project, branchName, userStories: [{id, title, description,
#     acceptanceCriteria, priority, passes, notes}] }
#
# Features:
#   • Per-task retries with Claude-generated error diagnosis
#   • Accumulated error history injected into retries
#   • Structured JSON state file — crash-safe, resumable
#   • Updates prd.json passes/notes fields in place
#   • Dark-mode terminal UI with progress tracking
#
# Requirements: bash 4+, jq, claude CLI

set -euo pipefail

# ── Theme (dark-mode optimized ANSI) ──────────────────────────────
RST="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[38;5;203m"
GRN="\033[38;5;114m"
YLW="\033[38;5;222m"
BLU="\033[38;5;111m"
MAG="\033[38;5;183m"
CYN="\033[38;5;116m"
WHT="\033[38;5;252m"
GRY="\033[38;5;243m"
ORG="\033[38;5;216m"
BG_GRN="\033[48;5;22m"

# ── Icons ─────────────────────────────────────────────────────────
ICO_PASS="✔"
ICO_FAIL="✘"
ICO_SKIP="⊘"
ICO_RUN="▶"
ICO_WAIT="◌"
ICO_RETRY="↻"
ICO_CLOCK="⏱"
ICO_WARN="⚠"
ICO_BRAIN="🧠"
ICO_TASK="◆"

# ── Defaults ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
STATE_FILE=""
LOG_DIR=""
ARCHIVE_DIR=""
LAST_BRANCH_FILE=""
RESUME=false
DRY_RUN=false
SHOW_COST=false
DIAG_LEARN=false

# Configurable — override via prd.json "config" block or env vars
# Precedence: CLI flags > prd.json config > env vars > defaults
MAX_RETRIES="${RALPH_MAX_RETRIES:-10}"
TIMEOUT_SEC="${RALPH_TIMEOUT:-600}"
MAX_TURNS="${RALPH_MAX_TURNS:-50}"
_CLI_RETRIES=""
_CLI_TIMEOUT=""
_CLI_TURNS=""

# ── Parse arguments ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --prd)       PRD_FILE="$2"; shift 2 ;;
    --prd=*)     PRD_FILE="${1#*=}"; shift ;;
    --resume)    RESUME=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --retries)   MAX_RETRIES="$2"; _CLI_RETRIES=1; shift 2 ;;
    --timeout)   TIMEOUT_SEC="$2"; _CLI_TIMEOUT=1; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; _CLI_TURNS=1; shift 2 ;;
    --cost)         SHOW_COST=true; shift ;;
    --diag-learn) DIAG_LEARN=true; shift ;;
    -h|--help)
      echo ""
      echo "Ralph Wiggum — Resilient Claude Code Task Runner"
      echo ""
      echo "Usage: ./ralph++.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --prd FILE       Path to the PRD file (default: ./prd.json)"
      echo "                   Accepts .json directly or .md (auto-converts via /ralph)"
      echo "  --resume         Resume a previous run, retrying pending/failed stories"
      echo "  --dry-run        Generate prompts without calling Claude"
      echo "  --retries N      Max retry attempts per story (default: 10)"
      echo "  --timeout SEC    Timeout in seconds per Claude call (default: 600)"
      echo "  --max-turns N    Max agentic turns per Claude call (default: 50)"
      echo "  --cost           Show per-story and total cost in the status table"
      echo "  --diag-learn     On failure: capture git diff and run a diagnosis call,"
      echo "                   then inject both into the retry prompt so the next"
      echo "                   attempt learns from what was tried"
      echo "  -h, --help       Show this help message"
      echo ""
      exit 0 ;;
    *) shift ;;
  esac
done

# ── Validate environment ─────────────────────────────────────────
for cmd in jq claude bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}${ICO_FAIL} Missing required command: ${BOLD}$cmd${RST}"
    exit 1
  fi
done

# ── Provide timeout fallback for macOS ─────────────────────────
if ! command -v timeout &>/dev/null; then
  timeout() {
    local duration="$1"; shift
    "$@" &
    local pid=$!
    (
      sleep "$duration"
      kill "$pid" 2>/dev/null
    ) &
    local watcher=$!
    local exit_code=0
    wait "$pid" 2>/dev/null || exit_code=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    # If the process was killed by us, return 124 (GNU timeout convention)
    if [ $exit_code -eq 137 ] || [ $exit_code -eq 143 ]; then
      return 124
    fi
    return $exit_code
  }
fi

if [ "$DIAG_LEARN" = true ] && ! command -v git &>/dev/null; then
  echo -e "${RED}${ICO_FAIL} --diag-learn requires ${BOLD}git${RST}${RED} but it's not installed${RST}"
  exit 1
fi

if [ ! -f "$PRD_FILE" ]; then
  echo -e "${RED}${ICO_FAIL} PRD file not found: ${BOLD}$PRD_FILE${RST}"
  exit 1
fi

# ── Convert .md PRD to JSON if needed ────────────────────────────
RALPH_PROMPT_FILE="$HOME/.claude/commands/ralph.md"

if [[ "$PRD_FILE" == *.md ]]; then
  JSON_PRD="${PRD_FILE%.md}.prd.json"

  # Skip conversion if JSON is newer than the .md source
  if [ -f "$JSON_PRD" ] && [ "$JSON_PRD" -nt "$PRD_FILE" ]; then
    log_info "Using cached conversion: ${DIM}$JSON_PRD${RST}"
  else
    if [ ! -f "$RALPH_PROMPT_FILE" ]; then
      echo -e "${RED}${ICO_FAIL} Ralph prompt not found: ${BOLD}$RALPH_PROMPT_FILE${RST}"
      echo -e "${RED}  Needed to convert .md to prd.json${RST}"
      exit 1
    fi

    log_info "Converting markdown PRD to JSON..."
    log_dim "Source: $PRD_FILE"

    local_ralph_prompt=$(cat "$RALPH_PROMPT_FILE")
    local_md_content=$(cat "$PRD_FILE")

    convert_output=$(timeout 120 claude \
      --print \
      --max-turns 1 \
      --dangerously-skip-permissions \
      -p "${local_ralph_prompt}

---

${local_md_content}

---

IMPORTANT: Output ONLY the raw prd.json content. No markdown fences, no explanation, just valid JSON." 2>/dev/null) || {
        echo -e "${RED}${ICO_FAIL} Markdown-to-JSON conversion failed (exit $?)${RST}"
        exit 1
      }

    # Extract JSON — strip markdown fences if Claude wrapped it anyway
    json_body=$(echo "$convert_output" | sed -n '/^[[:space:]]*{/,/^[[:space:]]*}/p')

    # Validate the JSON has userStories
    if ! echo "$json_body" | jq -e '.userStories | length > 0' &>/dev/null; then
      echo -e "${RED}${ICO_FAIL} Conversion produced invalid JSON (missing userStories)${RST}"
      echo -e "${GRY}Raw output saved to: ${JSON_PRD}.failed${RST}"
      echo "$convert_output" > "${JSON_PRD}.failed"
      exit 1
    fi

    echo "$json_body" | jq '.' > "$JSON_PRD"
    log_ok "Converted to: ${DIM}$JSON_PRD${RST}"
  fi

  PRD_FILE="$JSON_PRD"
fi

# ── Resolve output directory relative to PRD file location ───────
PRD_DIR="$(cd "$(dirname "$PRD_FILE")" && pwd)"
RALPH_DIR="$PRD_DIR/ralph++"
LOG_DIR="$RALPH_DIR/logs"
ARCHIVE_DIR="$RALPH_DIR/archive"
LAST_BRANCH_FILE="$RALPH_DIR/.last-branch"
mkdir -p "$RALPH_DIR"

# ── Load configuration from prd.json ─────────────────────────────
PROJECT=$(jq -r '.project // "ralph"' "$PRD_FILE")
BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE")
PRD_DESC=$(jq -r '.description // empty' "$PRD_FILE")

# Optional config overrides inside prd.json (only if CLI flag was not set)
_cfg_retries=$(jq -r '.config.maxRetries // empty' "$PRD_FILE" 2>/dev/null)
_cfg_timeout=$(jq -r '.config.timeoutSeconds // empty' "$PRD_FILE" 2>/dev/null)
_cfg_turns=$(jq -r '.config.maxTurns // empty' "$PRD_FILE" 2>/dev/null)
[ -z "$_CLI_RETRIES" ] && [ -n "$_cfg_retries" ] && MAX_RETRIES="$_cfg_retries"
[ -z "$_CLI_TIMEOUT" ] && [ -n "$_cfg_timeout" ] && TIMEOUT_SEC="$_cfg_timeout"
[ -z "$_CLI_TURNS" ]   && [ -n "$_cfg_turns" ]   && MAX_TURNS="$_cfg_turns"

# Sort user stories by priority
STORY_COUNT=$(jq '.userStories | length' "$PRD_FILE")
# Build priority-sorted index list
SORTED_INDICES=$(jq -r '[.userStories | to_entries | sort_by(.value.priority) | .[].key] | join(" ")' "$PRD_FILE")

STATE_FILE="$RALPH_DIR/.ralph-state-${PROJECT}.json"
mkdir -p "$LOG_DIR"

# ── UI Helpers ────────────────────────────────────────────────────

hr() {
  local char="${1:-─}"
  local cols
  cols=$(tput cols 2>/dev/null || echo 70)
  printf "${GRY}"
  printf '%*s' "$cols" '' | tr ' ' "$char"
  printf "${RST}\n"
}

banner() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 70)
  echo ""
  hr "═"
  printf "${BLU}${BOLD}  %-*s${RST}\n" "$((cols - 4))" "$1"
  [ -n "${2:-}" ] && printf "${GRY}  %-*s${RST}\n" "$((cols - 4))" "$2"
  hr "═"
}

log_info()  { echo -e "${BLU}${ICO_TASK}${RST} ${WHT}$*${RST}"; }
log_ok()    { echo -e "${GRN}${ICO_PASS}${RST} ${GRN}$*${RST}"; }
log_warn()  { echo -e "${YLW}${ICO_WARN}${RST} ${YLW}$*${RST}"; }
log_err()   { echo -e "${RED}${ICO_FAIL}${RST} ${RED}$*${RST}"; }
log_dim()   { echo -e "${GRY}  $*${RST}"; }

fmt_duration() {
  local sec=$1
  if (( sec < 60 )); then echo "${sec}s"
  elif (( sec < 3600 )); then echo "$((sec / 60))m $((sec % 60))s"
  else echo "$((sec / 3600))h $((sec % 3600 / 60))m"
  fi
}

fmt_tokens() {
  local n=$1
  if (( n >= 1000000 )); then
    printf "%.1fM" "$(echo "$n / 1000000" | bc -l)"
  elif (( n >= 1000 )); then
    printf "%.1fk" "$(echo "$n / 1000" | bc -l)"
  else
    printf "%d" "$n"
  fi
}

progress_bar() {
  local done=$1 total=$2 width=30
  (( total == 0 )) && total=1
  local pct=$((done * 100 / total))
  local filled=$((done * width / total))
  local empty=$((width - filled))
  printf "${GRN}"
  printf '%*s' "$filled" '' | tr ' ' '█'
  printf "${GRY}"
  printf '%*s' "$empty" '' | tr ' ' '░'
  printf " ${WHT}${BOLD}%3d%%${RST}" "$pct"
  printf " ${GRY}(%d/%d)${RST}" "$done" "$total"
}

# ── Status Table ──────────────────────────────────────────────────

print_status_table() {
  echo ""
  if [ "$SHOW_COST" = true ]; then
    printf "  ${BOLD}${WHT}%-8s %-10s %-38s %-10s %-5s %-10s %-10s %-10s %-8s${RST}\n" \
      "PRI" "ID" "TITLE" "STATUS" "TRY" "DURATION" "IN TOK" "OUT TOK" "COST"
  else
    printf "  ${BOLD}${WHT}%-8s %-10s %-38s %-10s %-5s %-10s %-10s %-10s${RST}\n" \
      "PRI" "ID" "TITLE" "STATUS" "TRY" "DURATION" "IN TOK" "OUT TOK"
  fi
  hr "─"

  for idx in $SORTED_INDICES; do
    local sid stitle spri sstate sattempt sdur scost sin sout icon color
    sid=$(jq -r ".userStories[$idx].id" "$PRD_FILE")
    stitle=$(jq -r ".userStories[$idx].title" "$PRD_FILE")
    spri=$(jq -r ".userStories[$idx].priority" "$PRD_FILE")

    # Truncate title
    if [ ${#stitle} -gt 36 ]; then
      stitle="${stitle:0:33}..."
    fi

    sstate=$(jq -r ".task_states[\"$sid\"].status // \"pending\"" "$STATE_FILE" 2>/dev/null || echo "pending")
    sattempt=$(jq -r ".task_states[\"$sid\"].attempt // 0" "$STATE_FILE" 2>/dev/null || echo "0")
    sdur=$(jq -r ".task_states[\"$sid\"].duration_sec // 0" "$STATE_FILE" 2>/dev/null || echo "0")
    sin=$(jq -r ".task_states[\"$sid\"].input_tokens // 0" "$STATE_FILE" 2>/dev/null || echo "0")
    sout=$(jq -r ".task_states[\"$sid\"].output_tokens // 0" "$STATE_FILE" 2>/dev/null || echo "0")

    case "$sstate" in
      success)  icon="$ICO_PASS"; color="$GRN" ;;
      failed)   icon="$ICO_FAIL"; color="$RED" ;;
      running)  icon="$ICO_RUN";  color="$YLW" ;;
      skipped)  icon="$ICO_SKIP"; color="$GRY" ;;
      *)        icon="$ICO_WAIT"; color="$GRY" ;;
    esac

    if [ "$SHOW_COST" = true ]; then
      scost=$(jq -r ".task_states[\"$sid\"].total_cost // 0" "$STATE_FILE" 2>/dev/null || echo "0")
      printf "  ${color}%-8s %-10s %-38s %s %-9s %-5s %-10s %-10s %-10s \$%-7s${RST}\n" \
        "[$spri]" "$sid" "$stitle" "$icon" "$sstate" "$sattempt" \
        "$(fmt_duration "$sdur")" "$(fmt_tokens "$sin")" "$(fmt_tokens "$sout")" "$(printf '%.3f' "$scost")"
    else
      printf "  ${color}%-8s %-10s %-38s %s %-9s %-5s %-10s %-10s %-10s${RST}\n" \
        "[$spri]" "$sid" "$stitle" "$icon" "$sstate" "$sattempt" \
        "$(fmt_duration "$sdur")" "$(fmt_tokens "$sin")" "$(fmt_tokens "$sout")"
    fi
  done
  echo ""
}

# ── Archive previous run ─────────────────────────────────────────

archive_if_branch_changed() {
  if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
    local last_branch
    last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
    if [ -n "$BRANCH" ] && [ -n "$last_branch" ] && [ "$BRANCH" != "$last_branch" ]; then
      local folder_name
      folder_name=$(echo "$last_branch" | sed 's|^ralph/||')
      local archive_folder="$ARCHIVE_DIR/$(date +%Y-%m-%d)-$folder_name"
      log_info "Archiving previous run: ${DIM}$last_branch${RST}"
      mkdir -p "$archive_folder"
      [ -f "$STATE_FILE" ] && cp "$STATE_FILE" "$archive_folder/"
      [ -d "$LOG_DIR" ] && cp -r "$LOG_DIR" "$archive_folder/" 2>/dev/null || true
      log_dim "Archived to: $archive_folder"
    fi
  fi
  [ -n "$BRANCH" ] && echo "$BRANCH" > "$LAST_BRANCH_FILE"
}

# ── State Management ──────────────────────────────────────────────

init_state() {
  if [ "$RESUME" = true ] && [ -f "$STATE_FILE" ]; then
    log_info "Resuming from existing state: ${DIM}$STATE_FILE${RST}"

    # On resume, reset any "running" tasks back to "pending" (crashed mid-task)
    local tmp
    tmp=$(mktemp)
    jq '
      .task_states |= with_entries(
        if .value.status == "running" then .value.status = "pending" else . end
      )
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    return
  fi

  local task_states="{}"
  for idx in $SORTED_INDICES; do
    local sid spasses
    sid=$(jq -r ".userStories[$idx].id" "$PRD_FILE")
    spasses=$(jq -r ".userStories[$idx].passes // false" "$PRD_FILE")

    # If prd.json already marks it as passes:true, start as success
    local init_status="pending"
    if [ "$spasses" = "true" ]; then
      init_status="success"
    fi

    task_states=$(echo "$task_states" | jq --arg t "$sid" --arg s "$init_status" \
      '.[$t] = {"status":$s,"attempt":0,"duration_sec":0,"total_cost":0,"input_tokens":0,"output_tokens":0,"errors":[],"started_at":null,"finished_at":null}')
  done

  jq -n \
    --arg project "$PROJECT" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson states "$task_states" \
    '{project:$project, started_at:$started, finished_at:null, task_states:$states}' \
    > "$STATE_FILE"
}

set_task_field() {
  local tid="$1" field="$2" value="$3"
  local tmp
  tmp=$(mktemp)
  jq --arg t "$tid" --arg f "$field" --arg v "$value" \
    '.task_states[$t][$f] = ($v | try tonumber // try (if . == "null" then null elif . == "[]" then [] else . end) // .)' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

set_task_json_field() {
  local tid="$1" field="$2" json_value="$3"
  local tmp
  tmp=$(mktemp)
  jq --arg t "$tid" --arg f "$field" --argjson v "$json_value" \
    '.task_states[$t][$f] = $v' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

get_task_field() {
  local tid="$1" field="$2"
  jq -r ".task_states[\"$tid\"].$field // empty" "$STATE_FILE" 2>/dev/null
}

# Update the prd.json passes field and notes for a given user story
update_prd_status() {
  local sid="$1" passes="$2" note="${3:-}"
  local tmp
  tmp=$(mktemp)
  jq --arg id "$sid" --argjson p "$passes" --arg n "$note" '
    .userStories |= map(
      if .id == $id then
        .passes = $p |
        if $n != "" then .notes = $n else . end
      else . end
    )
  ' "$PRD_FILE" > "$tmp" && mv "$tmp" "$PRD_FILE"
}

# ── Build prompt from a user story ────────────────────────────────

build_prompt() {
  local idx="$1"
  local title desc criteria_json criteria_text

  title=$(jq -r ".userStories[$idx].title" "$PRD_FILE")
  desc=$(jq -r ".userStories[$idx].description" "$PRD_FILE")
  criteria_json=$(jq -r ".userStories[$idx].acceptanceCriteria" "$PRD_FILE")

  # Format acceptance criteria as numbered list
  criteria_text=$(echo "$criteria_json" | jq -r 'to_entries | map("\(.key + 1). \(.value)") | join("\n")')

  cat <<PROMPT
# Task: ${title}

## Description
${desc}

## Acceptance Criteria
${criteria_text}

## Instructions
Complete this task. Work through each acceptance criterion methodically.
After implementing, verify ALL acceptance criteria are met before finishing.
If any criterion requires running tests or type checks, do so and fix any failures.
Do not skip any criterion — every one must pass.
PROMPT
}

# ── Core: Run a single task with retries ──────────────────────────

run_task() {
  local sid="$1" idx="$2"
  local task_log_dir attempt max_att
  task_log_dir="$LOG_DIR/$sid"
  mkdir -p "$task_log_dir"

  local title
  title=$(jq -r ".userStories[$idx].title" "$PRD_FILE")

  attempt=$(get_task_field "$sid" "attempt")
  attempt=$((${attempt:-0}))
  max_att=$MAX_RETRIES
  local last_attempt_diff="" last_raw_error="" pre_attempt_sha=""

  while (( attempt < max_att )); do
    attempt=$((attempt + 1))
    local start_ts exit_code duration
    start_ts=$(date +%s)

    set_task_field "$sid" "status" "running"
    set_task_field "$sid" "attempt" "$attempt"
    set_task_field "$sid" "started_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # ── Build prompt ──
    local base_prompt full_prompt
    base_prompt=$(build_prompt "$idx")
    full_prompt="$base_prompt"

    # Append retry context
    if (( attempt > 1 )); then
      if [ "$DIAG_LEARN" = true ] && [ -n "$last_attempt_diff" ]; then
        full_prompt="${base_prompt}

## ⚠️ RETRY CONTEXT (Attempt ${attempt} of ${max_att})

The previous attempt failed. Below is what it changed and why it failed.
Study the diff carefully — understand what was tried so you take a DIFFERENT approach.

### Failure Reason
${last_raw_error}

### Changes Made in Previous Attempt (git diff)
\`\`\`diff
${last_attempt_diff}
\`\`\`

Now complete the task. Fix what the previous attempt got wrong. Do NOT repeat the same mistakes."
      else
        full_prompt="${base_prompt}

## ⚠️ RETRY CONTEXT (Attempt ${attempt} of ${max_att})

The previous attempt failed with:
${last_raw_error}

Now complete the task using a corrected approach."
      fi
    fi

    # ── Display ──
    echo ""
    hr
    printf "  ${CYN}${ICO_RUN} ${BOLD}%-50s${RST}" "$title"
    if (( attempt > 1 )); then
      printf " ${ORG}${ICO_RETRY} retry %d/%d${RST}" "$attempt" "$max_att"
    fi
    printf "  ${GRY}${ICO_CLOCK} %s${RST}\n" "$(date +%H:%M:%S)"
    log_dim "Story: $sid  |  Priority: $(jq -r ".userStories[$idx].priority" "$PRD_FILE")"
    hr

    local out_file="$task_log_dir/attempt-${attempt}.out.json"
    local result_file="$task_log_dir/attempt-${attempt}.result.txt"

    if [ "$DRY_RUN" = true ]; then
      log_dim "[dry-run] Would run: claude --print -p <prompt> --output-format json"
      echo "$full_prompt" > "$task_log_dir/attempt-${attempt}.prompt.md"
      log_ok "Dry run — skipped (no changes to prd.json)"
      return 0
    fi

    # ── Capture git state for diff-context ──
    if [ "$DIAG_LEARN" = true ]; then
      pre_attempt_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi

    # ── Execute Claude ──
    exit_code=0
    timeout "$TIMEOUT_SEC" claude \
      --print \
      --output-format json \
      --max-turns "$MAX_TURNS" \
      --dangerously-skip-permissions \
      -p "$full_prompt" \
      > "$out_file" 2>/dev/null || exit_code=$?

    duration=$(( $(date +%s) - start_ts ))
    set_task_field "$sid" "duration_sec" "$duration"

    # Save the prompt used for this attempt
    echo "$full_prompt" > "$task_log_dir/attempt-${attempt}.prompt.md"

    # ── Parse result ──
    local is_error result_text cost_usd subtype num_turns
    # NOTE: jq's // operator treats false as falsy, so .is_error // true
    # would ALWAYS return true. Use if/then/else instead.
    is_error=$(jq -r 'if has("is_error") then .is_error else true end' "$out_file" 2>/dev/null || echo "true")
    result_text=$(jq -r '.result // empty' "$out_file" 2>/dev/null || echo "")
    cost_usd=$(jq -r '.total_cost_usd // 0' "$out_file" 2>/dev/null || echo "0")
    subtype=$(jq -r '.subtype // "unknown"' "$out_file" 2>/dev/null || echo "unknown")
    num_turns=$(jq -r '.num_turns // 0' "$out_file" 2>/dev/null || echo "0")

    # ── Extract tokens ──
    local in_tokens out_tokens cache_read cache_create
    in_tokens=$(jq -r '.usage.input_tokens // 0' "$out_file" 2>/dev/null || echo "0")
    out_tokens=$(jq -r '.usage.output_tokens // 0' "$out_file" 2>/dev/null || echo "0")
    cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' "$out_file" 2>/dev/null || echo "0")
    cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' "$out_file" 2>/dev/null || echo "0")

    # Accumulate cost and tokens
    local prev_cost new_cost prev_in prev_out
    prev_cost=$(get_task_field "$sid" "total_cost")
    prev_cost=${prev_cost:-0}
    new_cost=$(echo "${prev_cost} + ${cost_usd}" | bc 2>/dev/null || echo "$cost_usd")
    set_task_field "$sid" "total_cost" "$new_cost"

    prev_in=$(get_task_field "$sid" "input_tokens")
    prev_in=${prev_in:-0}
    set_task_field "$sid" "input_tokens" "$(( prev_in + in_tokens + cache_read + cache_create ))"

    prev_out=$(get_task_field "$sid" "output_tokens")
    prev_out=${prev_out:-0}
    set_task_field "$sid" "output_tokens" "$(( prev_out + out_tokens ))"

    echo "$result_text" > "$result_file"

    # ── Success ──
    if [ "$exit_code" -eq 0 ] && [ "$is_error" = "false" ] && [ -n "$result_text" ]; then
      log_ok "${BOLD}$sid${RST}${GRN} — $title"
      log_dim "Completed in $(fmt_duration "$duration") | Cost: \$$cost_usd"
      set_task_field "$sid" "status" "success"
      set_task_field "$sid" "finished_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      update_prd_status "$sid" "true" "Completed by Ralph (attempt $attempt, $(fmt_duration "$duration"))"
      return 0
    fi

    # ── Failure — collect error info ──
    local raw_error=""
    if [ "$exit_code" -eq 124 ]; then
      raw_error="TIMEOUT: Task exceeded ${TIMEOUT_SEC}s limit"
      log_err "${BOLD}$sid${RST}${RED} timed out after $(fmt_duration "$TIMEOUT_SEC")"
    elif [ "$subtype" = "error_max_turns" ]; then
      raw_error="MAX_TURNS: Claude hit max turns ($num_turns/$MAX_TURNS) without completing. Subtype: $subtype"
      log_err "${BOLD}$sid${RST}${RED} hit max turns ($num_turns) — subtype: $subtype"
    else
      raw_error="Exit code: $exit_code | is_error: $is_error | subtype: $subtype | num_turns: $num_turns | Output empty: $([ -z "$result_text" ] && echo yes || echo no)"
      log_err "${BOLD}$sid${RST}${RED} failed (exit $exit_code, subtype=$subtype, is_error=$is_error)"
    fi

    # ── Capture diff and error for retry context ──
    last_raw_error="$raw_error"
    if [ "$DIAG_LEARN" = true ] && [ -n "$pre_attempt_sha" ]; then
      local full_diff diff_lines
      full_diff=$(git diff "$pre_attempt_sha" 2>/dev/null || echo "")
      diff_lines=$(echo "$full_diff" | wc -l)
      echo "$full_diff" > "$task_log_dir/attempt-${attempt}.diff"
      if (( diff_lines > 200 )); then
        last_attempt_diff="$(echo "$full_diff" | head -200)
... [truncated — showing 200 of $diff_lines lines]"
      else
        last_attempt_diff="$full_diff"
      fi
    fi

    # ── Error analysis via separate Claude call (only with --diag-learn) ──
    local diagnosis=""
    if [ "$DIAG_LEARN" = true ]; then
      log_info "${ICO_BRAIN} Analyzing failure for retry guidance..."

      local analysis_prompt="You are a debugging assistant. A coding task was attempted by an AI agent and it failed.

TASK TITLE: ${title}

TASK DESCRIPTION:
$(jq -r ".userStories[$idx].description" "$PRD_FILE")

ACCEPTANCE CRITERIA:
$(jq -r ".userStories[$idx].acceptanceCriteria | join(\"\n\")" "$PRD_FILE")

RAW ERROR OUTPUT (last 2000 chars):
${raw_error:(-2000)}

AGENT'S OUTPUT (last 2000 chars):
${result_text:(-2000)}

Provide a concise, actionable diagnosis (max 10 lines):
1. Root cause — what specifically went wrong
2. Which acceptance criteria were NOT met and why
3. What approach should be AVOIDED on the next attempt
4. What specific alternative approach should be tried

Be concrete. Reference specific files, functions, or commands."

      diagnosis=$(timeout 120 claude \
        --print \
        --max-turns 1 \
        --dangerously-skip-permissions \
        -p "$analysis_prompt" 2>/dev/null) || {
          local diag_exit=$?
          diagnosis="[Analysis unavailable — exit $diag_exit]"
          log_dim "Diagnosis call failed (exit $diag_exit)"
        }

      # ── Display diagnosis ──
      echo -e "  ${MAG}${ICO_BRAIN} Diagnosis:${RST}"
      echo "$diagnosis" | head -10 | while IFS= read -r line; do
        echo -e "  ${GRY}│${RST} ${WHT}$line${RST}"
      done
      echo ""
    fi

    # ── Write failure log ──
    local failure_file="$task_log_dir/attempt-${attempt}.failure.log"
    cat > "$failure_file" <<FAILLOG
════════════════════════════════════════════════════════════════
FAILURE: $sid — $title
Attempt: $attempt / $max_att
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
════════════════════════════════════════════════════════════════

── Claude Response ──
exit_code:   $exit_code
is_error:    $is_error
subtype:     $subtype
num_turns:   $num_turns
duration:    $(fmt_duration "$duration")
cost_usd:    $cost_usd
tokens_in:   $in_tokens (+ cache_read=$cache_read, cache_create=$cache_create)
tokens_out:  $out_tokens

── Error ──
$raw_error

── Diagnosis ──
$diagnosis

── Result (last 3000 chars) ──
${result_text:(-3000)}
FAILLOG

    # ── Store error in state ──
    local error_entry
    error_entry=$(jq -n \
      --arg raw "$raw_error" \
      --arg diag "$diagnosis" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg code "$exit_code" \
      --arg dur "$duration" \
      '{timestamp:$ts, exit_code:$code, duration_sec:($dur|tonumber), raw_error:$raw, diagnosis:$diag}')

    local current_errors updated_errors
    current_errors=$(jq -r --arg t "$sid" '.task_states[$t].errors // []' "$STATE_FILE")
    updated_errors=$(echo "$current_errors" | jq --argjson e "$error_entry" '. + [$e]')
    set_task_json_field "$sid" "errors" "$updated_errors"

    # Update prd.json notes with latest failure info
    local fail_note="Failed attempt $attempt: $raw_error"
    [ -n "$diagnosis" ] && fail_note="Failed attempt $attempt: $(echo "$diagnosis" | head -1)"
    update_prd_status "$sid" "false" "$fail_note"

    if (( attempt < max_att )); then
      log_warn "Retrying now... (attempt $((attempt + 1))/$max_att)"
    fi
  done

  # ── Exhausted all retries ──
  log_err "${BOLD}$sid${RST}${RED} failed after $max_att attempts — giving up"
  set_task_field "$sid" "status" "failed"
  set_task_field "$sid" "finished_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  update_prd_status "$sid" "false" "FAILED after $max_att attempts"
  return 1
}

# ── Main Loop ─────────────────────────────────────────────────────

main() {
  local run_start
  run_start=$(date +%s)

  banner \
    "Ralph Wiggum — Task Runner" \
    "Project: $PROJECT  |  Stories: $STORY_COUNT  |  Max retries: $MAX_RETRIES  |  Timeout: ${TIMEOUT_SEC}s"

  [ -n "$BRANCH" ]   && log_info "Branch:  ${BOLD}$BRANCH${RST}"
  [ -n "$PRD_DESC" ]  && log_info "PRD:     ${DIM}$PRD_DESC${RST}"
  log_info "File:    ${DIM}$PRD_FILE${RST}"
  log_info "State:   ${DIM}$STATE_FILE${RST}"
  log_info "Logs:    ${DIM}$LOG_DIR${RST}"
  echo ""

  archive_if_branch_changed
  init_state

  # Count already-passed stories (from prd.json passes:true)
  local already_passed=0
  for idx in $SORTED_INDICES; do
    local sid sstate
    sid=$(jq -r ".userStories[$idx].id" "$PRD_FILE")
    sstate=$(get_task_field "$sid" "status")
    [ "$sstate" = "success" ] && already_passed=$((already_passed + 1))
  done

  if (( already_passed > 0 )); then
    log_info "${GRN}${already_passed} stories already passing — will skip them${RST}"
  fi

  print_status_table

  local completed=$already_passed
  local failed=0

  # Walk stories in priority order
  for idx in $SORTED_INDICES; do
    local sid sstate
    sid=$(jq -r ".userStories[$idx].id" "$PRD_FILE")
    sstate=$(get_task_field "$sid" "status")

    # Skip already completed
    if [ "$sstate" = "success" ]; then
      continue
    fi

    if run_task "$sid" "$idx"; then
      completed=$((completed + 1))
    else
      failed=$((failed + 1))
      # Continue to next task — don't block on failures
    fi

    print_status_table
  done

  # ── Final Summary ──
  local run_duration total_in total_out
  run_duration=$(( $(date +%s) - run_start ))
  total_in=$(jq '[.task_states[].input_tokens // 0 | tonumber] | add // 0' "$STATE_FILE")
  total_out=$(jq '[.task_states[].output_tokens // 0 | tonumber] | add // 0' "$STATE_FILE")

  echo ""
  banner "Run Complete" "$(date)"

  printf "  ${WHT}${BOLD}Progress:${RST}  "
  progress_bar "$completed" "$STORY_COUNT"
  echo ""
  echo ""

  printf "  ${GRN}${ICO_PASS} Passed:${RST}       %d\n" "$completed"
  printf "  ${RED}${ICO_FAIL} Failed:${RST}       %d\n" "$failed"
  printf "  ${CYN}${ICO_CLOCK} Duration:${RST}     %s\n" "$(fmt_duration "$run_duration")"
  printf "  ${MAG}📊 Input tok:${RST}   %s\n" "$(fmt_tokens "$total_in")"
  printf "  ${MAG}📊 Output tok:${RST}  %s\n" "$(fmt_tokens "$total_out")"
  if [ "$SHOW_COST" = true ]; then
    local total_cost
    total_cost=$(jq '[.task_states[].total_cost // 0 | tonumber] | add // 0' "$STATE_FILE")
    printf "  ${YLW}💰 Cost:${RST}        \$%s\n" "$(printf '%.4f' "$total_cost")"
  fi
  echo ""

  # Finalize state
  local tmp
  tmp=$(mktemp)
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.finished_at = $ts' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

  print_status_table

  if (( failed > 0 )); then
    log_warn "Some stories failed. Logs at: ${DIM}$LOG_DIR${RST}"
    log_info "To retry failed stories: ${BOLD}./ralph.sh --prd $PRD_FILE --resume${RST}"
    exit 1
  elif (( completed == STORY_COUNT )); then
    echo -e "  ${BG_GRN}${BOLD}${WHT}  🎉  ALL USER STORIES COMPLETED  ${RST}"
    echo ""
    exit 0
  else
    log_warn "Run ended with incomplete stories. Use --resume to continue."
    exit 1
  fi
}

main