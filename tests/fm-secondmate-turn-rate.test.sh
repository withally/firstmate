#!/usr/bin/env bash
# The secondmate turn-rate guard reads Pi's persisted session transcript and
# emits one signal-class wake for an unprompted high-rate episode.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-secondmate-turn-rate.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-turn-rate-tests)

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

write_meta() {  # <parent-home> <mate-home>
  mkdir -p "$1/state" "$1/config" "$2"
  printf 'kind=secondmate\nharness=pi\nhome=%s\nworktree=%s\n' "$2" "$2" \
    > "$1/state/mate.meta"
}

session_path() {  # <sessions-root> <mate-home>
  local slug=${2#/} dir
  slug=${slug//\//-}
  dir="$1/--$slug--"
  mkdir -p "$dir"
  printf '%s/session.jsonl\n' "$dir"
}

append_assistant_turn() {  # <file> <id> <timestamp> <command>
  printf '%s\n' \
    "{\"type\":\"message\",\"id\":\"a$2\",\"timestamp\":\"$3\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"c$2\",\"name\":\"bash\",\"arguments\":{\"command\":\"$4\"}}]}}" \
    >> "$1"
}

test_unprompted_pi_loop_signals_once_per_episode() {
  local parent mate sessions transcript now recent old i out rows
  parent="$TMP_ROOT/loop-parent"
  mate="$TMP_ROOT/loop-mate"
  sessions="$TMP_ROOT/loop-agent/sessions"
  write_meta "$parent" "$mate"
  transcript=$(session_path "$sessions" "$mate")
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  old=$(date -u -r "$(( $(date +%s) - 1200 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d '@'"$(( $(date +%s) - 1200 ))" '+%Y-%m-%dT%H:%M:%SZ')
  recent=$now
  printf '%s\n' \
    "{\"type\":\"session\",\"timestamp\":\"$old\",\"cwd\":\"$mate\"}" \
    "{\"type\":\"message\",\"timestamp\":\"$old\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Firstmate instruction waiting\"}]}}" \
    > "$transcript"
  i=1
  while [ "$i" -le 61 ]; do
    append_assistant_turn "$transcript" "$i" "$recent" "true"
    i=$((i + 1))
    append_assistant_turn "$transcript" "$i" "$recent" "ls state/mate.inbox/*.msg"
    i=$((i + 1))
  done

  out=$(FM_HOME="$parent" PI_CODING_AGENT_DIR="${sessions%/sessions}" "$GUARD" mate 2>&1)
  assert_contains "$out" 'signal: secondmate turn-rate exceeded: mate=mate' \
    "unprompted Pi loop did not emit the turn-rate signal"
  rows=$(grep -c "$(printf '\tsignal\t')" "$parent/state/.wake-queue" || true)
  [ "$rows" -eq 1 ] || fail "unprompted Pi loop queued $rows signal rows instead of one"

  out=$(FM_HOME="$parent" PI_CODING_AGENT_DIR="${sessions%/sessions}" "$GUARD" mate 2>&1)
  [ -z "$out" ] || fail "same high-rate episode emitted again: $out"
  rows=$(grep -c "$(printf '\tsignal\t')" "$parent/state/.wake-queue" || true)
  [ "$rows" -eq 1 ] || fail "same high-rate episode queued $rows signal rows instead of one"
  pass "secondmate turn-rate: an unprompted true/inbox loop emits one signal per episode"
}

test_doorbell_driven_pi_turns_do_not_signal() {
  local parent mate sessions transcript now i out
  parent="$TMP_ROOT/normal-parent"
  mate="$TMP_ROOT/normal-mate"
  sessions="$TMP_ROOT/normal-agent/sessions"
  write_meta "$parent" "$mate"
  transcript=$(session_path "$sessions" "$mate")
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s\n' \
    "{\"type\":\"session\",\"timestamp\":\"$now\",\"cwd\":\"$mate\"}" \
    "{\"type\":\"message\",\"timestamp\":\"$now\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Firstmate instruction waiting: list the inbox\"}]}}" \
    > "$transcript"
  i=1
  while [ "$i" -le 75 ]; do
    append_assistant_turn "$transcript" "$i" "$now" "do-real-work-$i"
    i=$((i + 1))
  done

  out=$(FM_HOME="$parent" PI_CODING_AGENT_DIR="${sessions%/sessions}" "$GUARD" mate 2>&1)
  [ -z "$out" ] || fail "doorbell-driven Pi turns emitted a signal: $out"
  [ ! -e "$parent/state/.wake-queue" ] || fail "doorbell-driven Pi turns queued a wake"
  pass "secondmate turn-rate: recent inbound activity suppresses a normal driven turn"
}

test_internal_whitespace_threshold_uses_default() {
  local parent mate sessions transcript now i out rows
  parent="$TMP_ROOT/threshold-parent"
  mate="$TMP_ROOT/threshold-mate"
  sessions="$TMP_ROOT/threshold-agent/sessions"
  write_meta "$parent" "$mate"
  printf '6 000\n' > "$parent/config/secondmate-turn-rate-threshold"
  transcript=$(session_path "$sessions" "$mate")
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s\n' "{\"type\":\"session\",\"timestamp\":\"$now\",\"cwd\":\"$mate\"}" > "$transcript"
  i=1
  while [ "$i" -le 61 ]; do
    append_assistant_turn "$transcript" "$i" "$now" "true"
    i=$((i + 1))
  done

  out=$(FM_HOME="$parent" PI_CODING_AGENT_DIR="${sessions%/sessions}" "$GUARD" mate 2>&1)
  assert_contains "$out" 'signal: secondmate turn-rate exceeded: mate=mate' \
    "an internally spaced threshold disabled the default turn-rate guard"
  rows=$(grep -c "$(printf '\tsignal\t')" "$parent/state/.wake-queue" || true)
  [ "$rows" -eq 1 ] || fail "malformed threshold queued $rows signal rows instead of one"
  pass "secondmate turn-rate: internal threshold whitespace falls back to the default"
}

test_wake_is_durable_before_episode_marker() {
  local parent mate sessions transcript now i fakebin marker real_mv rc out rows
  parent="$TMP_ROOT/marker-parent"
  mate="$TMP_ROOT/marker-mate"
  sessions="$TMP_ROOT/marker-agent/sessions"
  write_meta "$parent" "$mate"
  transcript=$(session_path "$sessions" "$mate")
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s\n' "{\"type\":\"session\",\"timestamp\":\"$now\",\"cwd\":\"$mate\"}" > "$transcript"
  i=1
  while [ "$i" -le 61 ]; do
    append_assistant_turn "$transcript" "$i" "$now" "true"
    i=$((i + 1))
  done

  fakebin="$parent/fakebin"
  mkdir -p "$fakebin"
  marker="$parent/state/.secondmate-turn-rate-mate"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
"$FM_REAL_MV" "$@" || exit $?
if [ "${FM_KILL_AFTER_RATE_MARKER:-0}" = 1 ] && [ "${2:-}" = "$FM_RATE_MARKER" ]; then
  kill -TERM "$PPID"
fi
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$parent" PI_CODING_AGENT_DIR="${sessions%/sessions}" \
    FM_REAL_MV="$real_mv" FM_RATE_MARKER="$marker" FM_KILL_AFTER_RATE_MARKER=1 \
    "$GUARD" mate > "$parent/first.out" 2>&1
  rc=$?
  set -u
  [ "$rc" -eq 143 ] || fail "marker crash fixture exited $rc instead of terminating after the marker rename"
  [ -e "$marker" ] || fail "marker crash fixture did not leave the episode marker"
  rows=$(grep -c "$(printf '\tsignal\t')" "$parent/state/.wake-queue" || true)
  [ "$rows" -eq 1 ] || fail "marker crash lost the durable wake before suppression"

  out=$(FM_HOME="$parent" PI_CODING_AGENT_DIR="${sessions%/sessions}" "$GUARD" mate 2>&1)
  [ -z "$out" ] || fail "durable marker replay emitted an unexpected duplicate: $out"
  rows=$(grep -c "$(printf '\tsignal\t')" "$parent/state/.wake-queue" || true)
  [ "$rows" -eq 1 ] || fail "durable marker replay queued $rows signal rows instead of one"
  pass "secondmate turn-rate: durable wake precedes episode suppression"
}

test_unprompted_pi_loop_signals_once_per_episode
test_doorbell_driven_pi_turns_do_not_signal
test_internal_whitespace_threshold_uses_default
test_wake_is_durable_before_episode_marker
