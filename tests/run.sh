#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/ralph++.sh"
BASE_PATH="$PATH"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "PASS: $1"
}

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

# Test 1: PRD config engine overrides default before validation
(
  test_dir="$tmp_root/engine-override"
  mkdir -p "$test_dir/bin"
  cp "$ROOT_DIR/tests/bin/gemini" "$test_dir/bin/gemini"
  cp "$ROOT_DIR/tests/bin/timeout" "$test_dir/bin/timeout"

  cat > "$test_dir/prd.json" <<'JSON'
{
  "project": "test",
  "branchName": "ralph/test",
  "description": "engine override",
  "config": {"engine": "gemini"},
  "userStories": [
    {
      "id": "US-1",
      "title": "t",
      "description": "d",
      "acceptanceCriteria": ["a"],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
JSON

  PATH="$test_dir/bin:$BASE_PATH" \
    "$SCRIPT" --prd "$test_dir/prd.json" --dry-run >/dev/null 2>&1 \
    || fail "engine override should not require claude when config.engine=gemini"
  pass "engine override"
)

# Test 2: Markdown conversion works (no 'local' at top-level) and writes .prd.json
(
  test_dir="$tmp_root/md-conversion"
  mkdir -p "$test_dir/bin" "$test_dir/home/.claude/commands"
  cp "$ROOT_DIR/tests/bin/claude" "$test_dir/bin/claude"
  cp "$ROOT_DIR/tests/bin/timeout" "$test_dir/bin/timeout"

  cat > "$test_dir/home/.claude/commands/ralph.md" <<'EOF_PROMPT'
You are a converter. Output JSON only.
EOF_PROMPT

  cat > "$test_dir/spec.md" <<'EOF_MD'
# Feature Spec

- id: US-1
  title: t
  description: d
  acceptanceCriteria:
    - a
  priority: 1
EOF_MD

  HOME="$test_dir/home" PATH="$test_dir/bin:$BASE_PATH" \
    "$SCRIPT" --prd "$test_dir/spec.md" --dry-run >/dev/null 2>&1 \
    || fail "markdown conversion failed"

  [ -f "$test_dir/spec.prd.json" ] || fail "spec.prd.json not created"
  jq -e '.userStories | length > 0' "$test_dir/spec.prd.json" >/dev/null \
    || fail "spec.prd.json missing userStories"
  pass "markdown conversion"
)

# Test 3: Resume hint references correct script name
if grep -q "./ralph++.sh --prd" "$SCRIPT"; then
  pass "resume hint"
else
  fail "resume hint references wrong script name"
fi

# Test 4: Codex exec flags and JSONL parsing
(
  test_dir="$tmp_root/codex"
  mkdir -p "$test_dir/bin"
  cp "$ROOT_DIR/tests/bin/codex" "$test_dir/bin/codex"
  cp "$ROOT_DIR/tests/bin/timeout" "$test_dir/bin/timeout"

  cat > "$test_dir/prd.json" <<'JSON'
{
  "project": "test",
  "branchName": "ralph/test",
  "description": "codex",
  "userStories": [
    {
      "id": "US-1",
      "title": "t",
      "description": "d",
      "acceptanceCriteria": ["a"],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
JSON

  args_file="$test_dir/codex.args"
  CODEX_ARGS_FILE="$args_file" PATH="$test_dir/bin:$BASE_PATH" \
    "$SCRIPT" --prd "$test_dir/prd.json" --engine codex --codex-model test-model >/dev/null 2>&1 \
    || fail "codex run should succeed"

  grep -q "^exec$" "$args_file" || fail "codex should use exec"
  grep -q "^--full-auto$" "$args_file" || fail "codex should use full-auto by default"
  grep -q "^-m$" "$args_file" || fail "codex should pass -m"
  grep -q "^test-model$" "$args_file" || fail "codex should pass model value"
  grep -q "^--json$" "$args_file" || fail "codex should request json output when supported"
  pass "codex exec flags"
)
