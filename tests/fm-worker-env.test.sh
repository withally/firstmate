#!/usr/bin/env bash
# Behavior tests for the worker launch environment boundary.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SCRUB="$ROOT/bin/fm-worker-env.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-env)
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/home"
cat > "$TMP_ROOT/worker" <<'SH'
#!/usr/bin/env bash
env | LC_ALL=C sort
SH
chmod +x "$TMP_ROOT/worker"

test_default_scrub_and_explicit_allowlist() {
  local allowlist out err rc
  allowlist="$TMP_ROOT/allowlist"
  out="$TMP_ROOT/out"
  err="$TMP_ROOT/err"
  printf '%s\n' GEMINI_API_KEY > "$allowlist"

  env \
    PATH="$PATH" HOME="$TMP_ROOT/home" SHELL=/bin/bash TERM=xterm-256color \
    LANG=en_US.UTF-8 LC_MESSAGES=C TMPDIR="$TMP_ROOT" \
    FM_HOME=/fleet HERDR_ENV=1 TMUX=fake,1,0 CLAUDE_CONFIG_DIR=/claude \
    ORDINARY_LEAK=visible DATAFORSEO_PASSWORD=dataforseo-secret \
    GEMINI_API_KEY=allowed-gemini GOOGLE_API_KEY=google-secret \
    LINEAR_API_KEY=linear-secret OPENROUTER_API_KEY=openrouter-secret \
    CLAUDE_TOKEN=claude-secret lowercase_password=lower-secret ACCESSKEY=key-secret \
    "$SCRUB" "$allowlist" --shell-command "$TMP_ROOT/worker" > "$out" 2> "$err"
  rc=$?

  expect_code 0 "$rc" "worker environment scrub should launch the worker"
  assert_grep 'GEMINI_API_KEY=allowed-gemini' "$out" \
    "an explicitly allowlisted secret must reach the worker"
  assert_grep 'FM_HOME=/fleet' "$out" "FM contract variables must reach the worker"
  assert_grep 'HERDR_ENV=1' "$out" "Herdr variables must reach the worker"
  assert_grep 'TMUX=fake,1,0' "$out" "tmux variables must reach the worker"
  assert_grep 'CLAUDE_CONFIG_DIR=/claude' "$out" \
    "harness variables must reach the worker when they are not secret-shaped"
  assert_grep 'LC_MESSAGES=C' "$out" "locale variables must reach the worker"
  assert_not_contains "$(cat "$out")" 'ORDINARY_LEAK=' \
    "unapproved ambient variables must not reach the worker"
  assert_not_contains "$(cat "$out")" 'DATAFORSEO_PASSWORD=' \
    "password-shaped variables must not reach the worker"
  assert_not_contains "$(cat "$out")" 'GOOGLE_API_KEY=' \
    "API-key-shaped variables must not reach the worker"
  assert_not_contains "$(cat "$out")" 'LINEAR_API_KEY=' \
    "API-key-shaped variables must not reach the worker"
  assert_not_contains "$(cat "$out")" 'OPENROUTER_API_KEY=' \
    "API-key-shaped variables must not reach the worker"
  assert_not_contains "$(cat "$out")" 'CLAUDE_TOKEN=' \
    "secret-shaped harness variables still require explicit allowlisting"
  assert_not_contains "$(cat "$out")" 'lowercase_password=' \
    "secret matching must be case-insensitive"
  assert_not_contains "$(cat "$out")" 'ACCESSKEY=' \
    "names ending in KEY must not reach the worker"
  grep -Eq '^worker environment scrub: dropped [0-9]+ variables$' "$err" \
    || fail "the scrub did not log only a dropped-variable count: $(cat "$err")"
  assert_not_contains "$(cat "$err")" 'secret' \
    "the scrub diagnostic must never print dropped values"
  pass "worker environment: defaults deny ambient and secret-shaped variables while an allowlisted key survives"
}

test_absent_allowlist_is_an_empty_optional_config() {
  local out err rc
  out="$TMP_ROOT/absent-out"
  err="$TMP_ROOT/absent-err"

  env PATH="$PATH" HOME="$TMP_ROOT/home" SHELL=/bin/bash TERM=xterm \
    FM_HOME=/fleet GOOGLE_API_KEY=blocked \
    "$SCRUB" "$TMP_ROOT/missing-allowlist" "$TMP_ROOT/worker" > "$out" 2> "$err"
  rc=$?

  expect_code 0 "$rc" "an absent optional worker environment allowlist should launch"
  assert_grep 'FM_HOME=/fleet' "$out" "the default worker contract disappeared without an allowlist"
  assert_not_contains "$(cat "$out")" 'GOOGLE_API_KEY=' \
    "an absent allowlist must not retain a secret-shaped name"
  pass "worker environment: an absent optional allowlist behaves as an empty allowlist"
}

test_default_scrub_and_explicit_allowlist
test_absent_allowlist_is_an_empty_optional_config

echo "# all fm-worker-env tests passed"
