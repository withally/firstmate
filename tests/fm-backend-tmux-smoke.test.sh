#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
#
# It also carries the harness-dependent window-identity check: a NON-DEFAULT
# section reconfigures the real server with base-index 1, automatic-rename on,
# and allow-rename on, then proves fm_backend_tmux_create_task's append-form
# creation survives base-index 1 and that its name pinning (automatic-rename AND
# allow-rename off) keeps the fm-<id> window findable by name even when a shell
# prompt hook emits the terminal rename escape - a verdict only a real tmux can
# give. tests/fm-tangle-guard.test.sh pins the exact command construction with a
# recording fake tmux; this file is the live guard for the behavior.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_window_name() {  # <target> <expected> [samples]
  # Poll until the window's name equals <expected>, proving a live rename landed.
  local target=$1 expected=$2 samples=${3:-100} name i=0
  while [ "$i" -lt "$samples" ]; do
    name=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)
    if [ "$name" = "$expected" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

window_shell_ready() {  # <target>
  # Bring a freshly-created window's interactive shell to a ready prompt, using
  # the same acknowledged-probe handshake as the send tests above.
  local target=$1 i=0
  while [ "$i" -lt 100 ]; do
    tmux send-keys -t "$target" C-c
    tmux send-keys -t "$target" -l "printf 'nd-rdy-%s\\n' ok"
    tmux send-keys -t "$target" Enter
    if wait_for_capture_text "$target" "nd-rdy-ok" 10; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- NON-DEFAULT tmux config: base-index 1 + automatic-rename/allow-rename on -
#
# The window-identity robustness in fm_backend_tmux_create_task (append-form
# creation and name pinning) only earns its keep when the captain's tmux differs
# from the shipped defaults. This exercises a REAL tmux server reconfigured with
# base-index 1, automatic-rename on, and allow-rename on - the verdict depends on
# what tmux itself does with those options, so a stub could not stand in - and
# proves that:
#   - append-form creation ("$ses:") does not collide under base-index 1: the
#     fm-<id> window is created, findable by name, and its returned stable window
#     id resolves to exactly that window;
#   - the name is PINNED against BOTH rename mechanisms: automatic-rename off (the
#     command-name rename) and allow-rename off (the terminal-escape title rename
#     a captain's shell prompt hook emits on every prompt). The latter is the
#     distinct protection: a `new-window -n` alone silences automatic-rename but
#     leaves allow-rename active, so an unpinned window is still renamed away from
#     fm-<id> - which would break the name-based worktree targeting in fm-spawn.sh
#     and let display-message fall back to the active client's window.

tmux set-option -g base-index 1
tmux set-option -g pane-base-index 1
tmux set-option -g automatic-rename on
tmux set-option -g allow-rename on

ND_SESSION="smokend"
ND_WINDOW="fm-smoke-nd1"
tmux new-session -d -s "$ND_SESSION" -x 200 -y 50 \
  || fail "real tmux (non-default): new-session failed"

# Confirm base-index 1 is genuinely in force for this session, so the collision
# case the append form guards against is actually being exercised.
nd_first_idx=$(tmux list-windows -t "$ND_SESSION" -F '#{window_index}' | head -n 1)
[ "$nd_first_idx" = 1 ] \
  || fail "non-default session's first window index is '$nd_first_idx', expected 1 (base-index 1 not applied)"

ND_WID=$(fm_backend_tmux_create_task "$ND_SESSION" "$ND_WINDOW" "$HOME") \
  || fail "fm_backend_tmux_create_task failed under base-index 1 / automatic-rename on"
case "$ND_WID" in
  @*) : ;;
  *) fail "create_task under non-default config returned '$ND_WID', expected a @<id> window id" ;;
esac
tmux list-windows -t "$ND_SESSION" -F '#{window_name}' | grep -qx "$ND_WINDOW" \
  || fail "non-default: the spawned window is not visible by its fm-<id> name (append form collided?)"
nd_resolved=$(tmux display-message -p -t "$ND_WID" '#{window_name}') \
  || fail "non-default: the returned window id '$ND_WID' did not resolve"
[ "$nd_resolved" = "$ND_WINDOW" ] \
  || fail "non-default: window id '$ND_WID' resolves to '$nd_resolved', expected '$ND_WINDOW'"
nd_ar=$(tmux show-window-options -t "$ND_WID" automatic-rename 2>/dev/null | awk '{print $2}')
[ "$nd_ar" = off ] \
  || fail "non-default: automatic-rename on the spawned window is '$nd_ar', expected off (name not pinned)"
nd_al=$(tmux show-window-options -t "$ND_WID" allow-rename 2>/dev/null | awk '{print $2}')
[ "$nd_al" = off ] \
  || fail "non-default: allow-rename on the spawned window is '$nd_al', expected off (escape-rename not pinned)"
pass "real tmux (non-default): create_task appends under base-index 1, returns a resolving window id, and pins automatic-rename/allow-rename off"

# Behavioral name-pinning proof against the escape-title rename (allow-rename).
# A control window built the OLD way ("new-window -n" only, no pinning) leaves
# allow-rename active; the spawned window carries the fix (allow-rename off). Both
# receive the SAME terminal escape a shell prompt hook emits (ESC k <title> ESC \).
# The control MUST be renamed by it (proving the escape path is genuinely live in
# this server, so the pinning assertion is never vacuous), while the spawned
# window MUST keep its fm-<id> name and stay findable by that name.
ND_CTRL_WID=$(tmux new-window -dP -F '#{window_id}' -t "$ND_SESSION:" -n "ctrl-oldstyle")
window_shell_ready "$ND_CTRL_WID" || fail "non-default: control window shell did not become ready"
window_shell_ready "$ND_WID"      || fail "non-default: spawned window shell did not become ready"

# ESC k <title> ESC \  is tmux's window-rename escape, honored only when
# allow-rename is on. Sent to the control's stable id (its name is about to change).
tmux send-keys -t "$ND_CTRL_WID" -l $'printf "\\033kescaped-ctrl\\033\\\\"'
tmux send-keys -t "$ND_CTRL_WID" Enter
tmux send-keys -t "$ND_WID"      -l $'printf "\\033kescaped-fix\\033\\\\"'
tmux send-keys -t "$ND_WID"      Enter

wait_for_window_name "$ND_CTRL_WID" "escaped-ctrl" \
  || fail "non-default: the control (allow-rename on) was NOT renamed by the escape - the escape path is inert here, so the pinning check would be vacuous"
nd_pinned=$(tmux display-message -p -t "$ND_WID" '#{window_name}')
[ "$nd_pinned" = "$ND_WINDOW" ] \
  || fail "non-default: the escape renamed the spawned window to '$nd_pinned'; the fm-<id> name was not pinned (allow-rename off missing?)"
tmux list-windows -t "$ND_SESSION" -F '#{window_name}' | grep -qx "$ND_WINDOW" \
  || fail "non-default: after the rename escape the spawned window is no longer findable by its fm-<id> name"
pass "real tmux (non-default): an escape-title rename renames an unpinned window but cannot rename the spawned fm-<id> window"

cleanup_all
trap - EXIT
