#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# Cross-backend screen matrix adapted from upstream 7f051002.
# Muse is deliberately absent because this fork does not verify that adapter.
ESC=$(printf '\033')
NBSP=$(printf '\302\240')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20'
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'

assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

test_matrix_claude_bare_nbsp_row() {
  local screen typed
  screen=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  bypass permissions'
  assert_screen "claude idle on tmux" empty "$CAPS_TMUX" "$screen" 2 probe-absent
  assert_screen "claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' probe-absent
  assert_screen "claude idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  typed=$'────────────────────────\n❯ fix the login bug\n────────────────────────'
  assert_screen "claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  assert_screen "claude typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  pass "matrix: claude's ❯+NBSP row is locale-safe across every backend profile"
}

test_matrix_codex_dim_hint_row() {
  local styled plain
  styled=$'banner\n'"${ESC}[1m›${ESC}[0m ${ESC}[2mUse /skills to list available skills${ESC}[0m"
  plain=$'banner\n› Use /skills to list available skills'
  assert_screen "codex idle on tmux" empty "$CAPS_TMUX" "$styled" 1
  assert_screen "codex idle on herdr" empty "$CAPS_STYLED" "$styled"
  assert_screen "codex idle on zellij" empty "$CAPS_STYLED_NOID" "$styled"
  assert_screen "codex idle on plain backends" unknown "$CAPS_PLAIN" "$plain"
  pass "matrix: codex's dim hint is empty with styling and unknown without it"
}

test_matrix_pi_separated_needs_identity() {
  local screen typed pi_idle pi_working none
  screen=$'transcript\n────────────────────────\n\n────────────────────────\n footer'
  pi_idle=$(printf 'pi\tidle')
  pi_working=$(printf 'pi\tworking')
  none=$(printf 'zsh\t')
  assert_screen "pi idle with identity" empty "$CAPS_STYLED" "$screen" '' "$pi_idle"
  assert_screen "pi idle on tmux with identity" empty "$CAPS_TMUX" "$screen" 2 "$pi_idle"
  assert_screen "pi idle on zellij" unknown "$CAPS_STYLED_NOID" "$screen"
  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")" = need-identity ] \
    || fail "an identity-capable profile should request the lazy identity probe"
  assert_screen "pi pair without identity capability" unknown "$CAPS_PLAIN" "$screen"
  assert_screen "working pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_working"
  assert_screen "sleep-pane counterexample" unknown "$CAPS_TMUX" "$screen" 2 "$none"
  assert_screen "absent identity cannot prove blank pi pair" unknown "$CAPS_TMUX" "$screen" 2 probe-absent
  typed=$'────────────────────────\nfix the flaky test\n────────────────────────'
  assert_screen "pi typed" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  typed=$'────────────────────────\n❯\n────────────────────────'
  assert_screen "pi lone-glyph draft with identity" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  assert_screen "pi lone-glyph draft on tmux" pending "$CAPS_TMUX" "$typed" 1 "$pi_idle"
  assert_screen "lone glyph without identity capability" empty "$CAPS_STYLED_NOID" "$typed"
  assert_screen "lone glyph on plain backend" empty "$CAPS_PLAIN" "$typed"
  assert_screen "lone glyph with non-pi identity" empty "$CAPS_STYLED" "$typed" '' "$none"
  pass "matrix: Pi's separated composer needs identity plus structure"
}

test_matrix_opencode_leftbar_signals() {
  local screen typed dim_screen out
  screen=$'  ┃\n  ┃  Ask anything... "What is the tech stack?"\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
  dim_screen=$'  ┃\n  ┃  '"${ESC}[2mAsk anything...${ESC}[0m"$'\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀'
  assert_screen "opencode idle on tmux" empty "$CAPS_TMUX" "$dim_screen" 1
  assert_screen "opencode idle on herdr" empty "$CAPS_STYLED" "$dim_screen"
  assert_screen "opencode idle on zellij" empty "$CAPS_STYLED_NOID" "$dim_screen"
  assert_screen "opencode idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  out=$(FM_COMPOSER_IDLE_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_TMUX" "$dim_screen" 1)
  [ "$out" = empty ] || fail "a dim opencode hint must stay empty via ghost stripping, got '$out'"
  typed=$'┃\n┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "opencode typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  Ask anything... please investigate\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode placeholder-like input on tmux" pending "$CAPS_TMUX" "$typed" 0
  assert_screen "opencode placeholder-like input on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high'
  assert_screen "opencode multiline draft above blank cursor row" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: OpenCode's left-bar composer scans its full active run"
}

test_matrix_grok_titled_bottom_border() {
  local titled plain_border typed placeholder_draft
  titled=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  plain_border=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯'
  assert_screen "grok titled on tmux" empty "$CAPS_TMUX" "$titled" 1
  assert_screen "grok titled on tmux bottom-border cursor" empty "$CAPS_TMUX" "$titled" 2
  assert_screen "grok titled on herdr" empty "$CAPS_STYLED" "$titled"
  placeholder_draft=$'  ╭──────────────────────────────────────╮\n  │ ❯ Type a message...                  │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  assert_screen "grok bright placeholder-like draft on tmux" pending "$CAPS_TMUX" "$placeholder_draft" 1
  assert_screen "grok placeholder on plain backends" empty "$CAPS_PLAIN" "$placeholder_draft"
  assert_screen "grok titled on cmux/orca" empty "$CAPS_PLAIN" "$titled"
  assert_screen "grok titled on zellij" empty "$CAPS_STYLED_NOID" "$titled"
  assert_screen "grok untitled border" empty "$CAPS_TMUX" "$plain_border" 1
  typed=$'  ╭──────────────────────────────────────╮\n  │ ❯ deploy the fix                     │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  assert_screen "grok typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: Grok's titled bottom border retains proven box geometry"
}

test_matrix_kimi_bordered_shell_glyph_box() {
  local screen
  screen=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  assert_screen "kimi idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "kimi idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "kimi idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "kimi idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  pass "matrix: Kimi's bordered shell-glyph box uses the shared owner"
}

test_matrix_claude_inside_zellij_ansi_dump() {
  local screen plain
  screen=$'zellij pane transcript\n'"${ESC}[m❯${NBSP}"
  plain=$'zellij pane transcript\n❯'"$NBSP"
  assert_screen "claude-in-zellij on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "claude-in-zellij on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "claude-in-zellij on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude-in-zellij on plain backends" empty "$CAPS_PLAIN" "$plain"
  pass "matrix: Claude's real zellij ANSI shape is locale-safe"
}

test_strict_blank_row_divergence() {
  local out
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'some output\nmore output\n' 2)
  [ "$out" = unknown ] || fail "a blank unidentified cursor row must be unknown, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\n$ ' 1)
  [ "$out" = unknown ] || fail "a dead-shell prompt row must be unknown, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'Working...' 0)
  [ "$out" = unknown ] || fail "a bare busy-footer row must be unknown, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\nhuman draft text' 1)
  [ "$out" = unknown ] || fail "an unidentified text row must be unknown, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'\n\n')
  [ "$out" = unknown ] || fail "a blank screen must be unknown, got '$out'"
  pass "strict posture: blank and unidentified rows are unknown"
}

test_bare_wrap_region_classifies() {
  local wrapped ghost_wrapped out
  wrapped=$'❯ a very long steer message that\nwraps onto the following line'
  assert_screen "wrapped typed input" pending "$CAPS_TMUX" "$wrapped" 1
  ghost_wrapped=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$ghost_wrapped" 1)
  [ "$out" = empty ] || fail "a wrapped ghost suggestion should prove empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n────────────────\nbelow the rule' 2)
  [ "$out" = unknown ] || fail "a rule must break the wrap region, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n$ live shell' 1)
  [ "$out" = unknown ] || fail "a shell prompt must not become wrapped input, got '$out'"
  pass "fm_composer_classify_screen: bare wrapped input stays structurally identified"
}

test_cursorless_candidate_selection() {
  local stale live box screen out
  stale=$'old transcript\n❯\nprocess exited\n$'
  assert_screen "stale composer above dead shell on herdr" unknown "$CAPS_STYLED" "$stale"
  assert_screen "stale composer above dead shell on zellij" unknown "$CAPS_STYLED_NOID" "$stale"
  assert_screen "stale composer above dead shell on cmux/orca" unknown "$CAPS_PLAIN" "$stale"
  live=$'transcript shell snippet\n$ echo old output\nmore transcript\n❯'
  assert_screen "shell transcript above live composer" empty "$CAPS_STYLED_NOID" "$live"
  box=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...'
  assert_screen "stale box above activity" unknown "$CAPS_STYLED_NOID" "$box"
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "banner above live Claude row" empty "$CAPS_PLAIN" "$screen"
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nstartup complete\n╭────────────────────────╮\n│ ❯ clipped live draft  '
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$out" = unknown ] || fail "an incomplete lower box must invalidate an earlier box, got '$out'"
  pass "fm_composer_classify_screen: cursorless selection rejects stale and incomplete candidates"
}

# A composer taller than the bounded tail window (FM_COMPOSER_CAPTURE_LINES)
# keeps only its content rows and its bottom border in view. The side borders
# are the same container proof a complete box carries, so the shape must stay a
# container and a long draft must keep earning its Enter retries
# (fm_composer_submit_retry_core only continues on pending/pending-unproven) -
# but with the top border and its geometry proof out of window, it is always
# ambiguous, so blank rows can never become a positive empty.
test_clipped_box_keeps_container_proof() {
  local clipped blank stale
  clipped=$'│ > a draft that started above  │\n│ the capture window            │\n╰───────────────────────────────╯'
  assert_screen "clipped box on herdr" pending-unproven "$CAPS_STYLED" "$clipped"
  assert_screen "clipped box on zellij" pending-unproven "$CAPS_STYLED_NOID" "$clipped"
  assert_screen "clipped box on cmux/orca" pending-unproven "$CAPS_PLAIN" "$clipped"
  blank=$'│                               │\n╰───────────────────────────────╯'
  assert_screen "clipped blank box is never empty" unknown "$CAPS_PLAIN" "$blank"
  assert_screen "clipped box under activity" unknown "$CAPS_PLAIN" \
    $'│ > a draft                     │\n╰───────────────────────────────╯\nWorking on request...'
  assert_screen "clipped box with a shifted indent" unknown "$CAPS_PLAIN" \
    $'  │ > a draft                   │\n╰───────────────────────────────╯'
  assert_screen "clipped box with a mixed border family" unknown "$CAPS_PLAIN" \
    $'┃ > a draft                     ┃\n╰───────────────────────────────╯'
  assert_screen "side rows above the first captured row" unknown "$CAPS_PLAIN" \
    $'transcript line\n│ > a draft                     │\n╰───────────────────────────────╯'
  stale=$'│ old │\n╰──────╯\n│ newer unclosed draft │'
  assert_screen "clipped box under a newer container" unknown "$CAPS_PLAIN" "$stale"
  [ "$(fm_composer_extract_selected_content "$CAPS_PLAIN" "$clipped")" \
    = 'a draft that started above the capture window' ] \
    || fail "clipped-box extraction should return the whole visible draft"
  pass "fm_composer_classify_screen: a top-clipped box stays a container, always ambiguous"
}

test_titled_bottom_requires_matching_width() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰─ Grok ─╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 1)
  [ "$out" = unknown ] || fail "a short titled bottom must not prove an empty box, got '$out'"
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 2)
  [ "$out" = empty ] || fail "a cursor on a proven box bottom should classify content, got '$out'"
  pass "fm_composer_classify_screen: titled and cursor-bottom boxes retain geometry proof"
}

test_selected_content_is_composer_scoped() {
  local screen out
  screen=$'hello captain in transcript\n╭────────────────────╮\n│ unrelated          │\n│ draft               │\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'unrelated draft' ] || fail "box extraction should be composer-scoped, got '$out'"
  screen=$'hello captain in transcript\n┃ hello\n┃ captain\n┃ Build · GPT-5.5 Fast OpenAI · high'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'hello captain' ] || fail "left-bar extraction should exclude footer furniture, got '$out'"
  screen=$'❯ a legitimately long steer that\nwraps across the next bare row\n\ntranscript below the break'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'a legitimately long steer that wraps across the next bare row' ] \
    || fail "bare extraction should include only its contiguous wrap region, got '$out'"
  screen=$'❯ stale composer\n$ live shell'
  if out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen"); then
    fail "a lower live shell must invalidate composer extraction, got '$out'"
  fi
  pass "fm_composer_extract_selected_content: scopes user content and excludes furniture"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_matrix_claude_bare_nbsp_row
test_matrix_codex_dim_hint_row
test_matrix_pi_separated_needs_identity
test_matrix_opencode_leftbar_signals
test_matrix_grok_titled_bottom_border
test_matrix_kimi_bordered_shell_glyph_box
test_matrix_claude_inside_zellij_ansi_dump
test_strict_blank_row_divergence
test_bare_wrap_region_classifies
test_cursorless_candidate_selection
test_clipped_box_keeps_container_proof
test_titled_bottom_requires_matching_width
test_selected_content_is_composer_scoped
