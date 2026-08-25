#!/usr/bin/env bash
# Reproduction of the reported Herdr submit defect: a steer whose post-Enter
# surface is momentarily unreadable was reported to the supervisor as "unknown"
# (delivery neither confirmed nor retried), even though the composer still held
# the text one read later.
# Drives the real bin/backends/herdr.sh submit path in <tree>, with only the
# lowest-level Herdr CLI touches stubbed: the first surface read is unreadable,
# the next read shows the text still pending in the composer.
set -u
TREE=$1; LABEL=$2
dir=$(mktemp -d "${TMPDIR:-/tmp}/herdr-submit-repro.XXXXXX"); log="$dir/enters"; : > "$log"
out=$(FM_ENTER_LOG="$log" FM_CASE_DIR="$dir" bash -c '
  . "$0/bin/backends/herdr.sh"
  fm_backend_herdr_parse_target() { FM_BACKEND_HERDR_SESSION=default; FM_BACKEND_HERDR_PANE=w1:p2; }
  fm_backend_herdr_send_literal() { return 0; }
  fm_backend_herdr_send_key() { printf "enter\n" >> "$FM_ENTER_LOG"; return 0; }
  fm_backend_herdr_agent_status_raw() { printf idle; }
  fm_backend_herdr_classify_submit_agent_status() { printf idle; }
  fm_backend_herdr_rendered_busy_state() { printf idle; }
  fm_backend_herdr_submit_confirm_budget() { printf 0.01; }
  fm_backend_herdr_wait_for_working() {
    n=$(cat "$FM_CASE_DIR/waits" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FM_CASE_DIR/waits"
    if [ "$n" -eq 1 ]; then printf unknown; else printf busy; fi
  }
  fm_backend_herdr_composer_state() {
    n=$(cat "$FM_CASE_DIR/composers" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FM_CASE_DIR/composers"
    if [ "$n" -eq 1 ]; then printf unknown; else printf pending; fi
  }
  sleep() { :; }
  fm_backend_herdr_send_text_submit default:w1:p2 "captain: status please" 3 0.01 0
' "$TREE")
printf '%-26s submit verdict reported to the supervisor: %-8s Enter keypresses sent: %s\n' \
  "$LABEL" "$out" "$(wc -l < "$log" | tr -d ' ')"
rm -rf "$dir"
