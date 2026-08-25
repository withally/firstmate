#!/usr/bin/env bash
# Opt-in real-Pi regular-TUI regression for transcript shrink after a
# viewport-filling tool result is expanded and collapsed.
set -u

if [ "${FM_PI_CLEAR_ON_SHRINK_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_CLEAR_ON_SHRINK_LIVE_E2E=1 to run the isolated Pi shrink regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

LAB=$(fm_test_tmproot fm-pi-clear-on-shrink-live-e2e)
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
CONFIG_DIR="$LAB/pi-config"
SESSIONS_DIR="$LAB/sessions"
SOCKET="fm-pi-shrink-$$"
SESSION=pi-shrink
SNAPSHOT="$LAB/pane.txt"
PREV_SNAPSHOT="$LAB/pane-prev.txt"

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

capture_viewport() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" >"$SNAPSHOT" 2>/dev/null || true
}

capture_history() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -500 >"$SNAPSHOT" 2>/dev/null || true
}

wait_for_text() {
  local text=$1 attempt=0
  while [ "$attempt" -lt 240 ]; do
    capture_viewport
    grep -Fq "$text" "$SNAPSHOT" && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_history_text() {
  local text=$1 attempt=0
  while [ "$attempt" -lt 240 ]; do
    capture_history
    grep -Fq "$text" "$SNAPSHOT" && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

send_line() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

CALM_SHIP_HULL='\__/'
SETTLE_SAMPLE_SECONDS=0.06
SETTLE_STABLE_INTERVALS=4

settle_viewport() {
  local marker=$1 label=$2 attempt=0 stable=0
  : >"$PREV_SNAPSHOT"
  while [ "$attempt" -lt 400 ]; do
    cp "$SNAPSHOT" "$PREV_SNAPSHOT" 2>/dev/null || true
    sleep "$SETTLE_SAMPLE_SECONDS"
    capture_viewport
    if grep -Fq "$marker" "$SNAPSHOT" \
      && ! tail -12 "$SNAPSHOT" | grep -Fq "$CALM_SHIP_HULL" \
      && cmp -s "$SNAPSHOT" "$PREV_SNAPSHOT"; then
      stable=$((stable + 1))
      [ "$stable" -ge "$SETTLE_STABLE_INTERVALS" ] && return 0
    else
      stable=0
    fi
    attempt=$((attempt + 1))
  done
  cat "$SNAPSHOT" >&2
  fail "$label did not hold $marker in a viewport that stayed unchanged across $SETTLE_STABLE_INTERVALS samples with the Calm working ship gone"
}

assert_no_empty_region_before() {
  local marker=$1 label=$2 blank_run
  blank_run=$(awk -v marker="$marker" '
    BEGIN { run = 0 }
    index($0, marker) { print run; found=1; exit }
    /^[[:space:]]*$/ { run += 1; next }
    { run = 0 }
    END { if (!found) exit 2 }
  ' "$SNAPSHOT") || fail "$label did not render $marker in the visible viewport"
  [ "$blank_run" -le 3 ] \
    || fail "$label left a $blank_run-row empty region above $marker"
}

mkdir -p \
  "$PROJECT/.pi/extensions/lib" \
  "$PROJECT/node_modules/@earendil-works" \
  "$HOME_DIR/config" \
  "$CONFIG_DIR" \
  "$SESSIONS_DIR"
fm_git_init_commit "$PROJECT"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || fail "installed @earendil-works/pi-coding-agent package not found"
ln -s "$PI_PACKAGE_DIR" "$PROJECT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$PROJECT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$PROJECT/node_modules/typebox"
printf '%s\n' '{"type":"module"}' >"$PROJECT/package.json"
printf '%s\n' on >"$HOME_DIR/config/calm"
printf '%s\n' '{"hideThinkingBlock":true,"compaction":{"keepRecentTokens":200}}' >"$CONFIG_DIR/settings.json"

cat >"$PROJECT/shrink-provider.ts" <<'TS'
import {
  createFauxCore,
  fauxAssistantMessage,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const tallResult = (label: string): string => Array.from(
  { length: 96 },
  (_, index) => `${label}_ROW_${String(index + 1).padStart(3, "0")}`,
).join("\n");

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "pi-shrink-e2e-api",
    provider: "pi-shrink-e2e",
    models: [{
      id: "deterministic",
      name: "Pi clear-on-shrink E2E",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 100000,
      maxTokens: 10000,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  faux.setResponses([
    fauxAssistantMessage(
      fauxToolCall("viewport_fill", { label: "BEFORE_COMPACT" }, { id: "viewport_before" }),
      { stopReason: "toolUse" },
    ),
    fauxAssistantMessage(fauxText(`${"context prose ".repeat(450)}\nAFTER_TOOL_RESULT`)),
    fauxAssistantMessage(fauxText("NEXT_VISIBLE_CONTENT")),
    fauxAssistantMessage(fauxText("COMPACTED_SHRINK_FIXTURE")),
    fauxAssistantMessage(
      fauxToolCall("viewport_fill", { label: "AFTER_COMPACT" }, { id: "viewport_after" }),
      { stopReason: "toolUse" },
    ),
    fauxAssistantMessage(fauxText("AFTER_COMPACT_TOOL_RESULT")),
    fauxAssistantMessage(fauxText("NEXT_VISIBLE_AFTER_COMPACT")),
  ]);
  pi.registerProvider("pi-shrink-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerTool({
    name: "viewport_fill",
    label: "Viewport fill",
    description: "Return a deterministic viewport-filling result.",
    parameters: Type.Object({ label: Type.String() }),
    async execute(_toolCallId, params) {
      return {
        content: [{ type: "text", text: tallResult(params.label) }],
        details: {},
      };
    },
  });
  pi.registerCommand("pi-shrink-e2e", {
    description: "Select the deterministic shrink-regression model.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("pi-shrink-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("Pi shrink-regression model unavailable");
      }
    },
  });
}
TS

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 100 -y 36 \
  "cd '$PROJECT' && env FM_HOME='$HOME_DIR' PI_CODING_AGENT_DIR='$CONFIG_DIR' PI_OFFLINE=1 PI_CLEAR_ON_SHRINK=1 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions --tui-mode regular -e ./.pi/extensions/fm-calm.ts -e ./shrink-provider.ts --session-dir '$SESSIONS_DIR'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 20"

wait_for_text "shrink-provider.ts" || fail "Pi shrink E2E did not reach the ready composer"
send_line /pi-shrink-e2e
sleep 0.1
send_line "Run viewport_fill once, then finish."
wait_for_text AFTER_TOOL_RESULT || fail "Pi shrink E2E did not complete the pre-compaction tool turn"

tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_history_text BEFORE_COMPACT_ROW_096 || {
  cat "$SNAPSHOT" >&2
  fail "Ctrl+O did not expand the viewport-filling tool result"
}
tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_text AFTER_TOOL_RESULT || fail "collapsed pre-compaction result hid the next visible reply"
send_line "Reply after the collapsed tool result."
wait_for_text NEXT_VISIBLE_CONTENT || fail "Pi shrink E2E did not render content after the pre-compaction collapse"
settle_viewport NEXT_VISIBLE_CONTENT "pre-compaction collapse"
assert_no_empty_region_before NEXT_VISIBLE_CONTENT "pre-compaction collapse"

send_line /compact
wait_for_text "Compacted from" || fail "Pi shrink E2E did not complete a real compaction rebuild"
send_line "Run viewport_fill once after compaction, then finish."
wait_for_text AFTER_COMPACT_TOOL_RESULT || fail "Pi shrink E2E did not complete the post-compaction tool turn"
tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_history_text AFTER_COMPACT_ROW_096 || {
  cat "$SNAPSHOT" >&2
  fail "Ctrl+O did not expand the post-compaction tool result"
}
tmux -L "$SOCKET" send-keys -t "$SESSION" C-o
wait_for_text AFTER_COMPACT_TOOL_RESULT || fail "collapsed post-compaction result hid the next visible reply"
send_line "Reply after the post-compaction collapsed tool result."
wait_for_text NEXT_VISIBLE_AFTER_COMPACT || fail "Pi shrink E2E did not render content after the post-compaction collapse"
settle_viewport NEXT_VISIBLE_AFTER_COMPACT "post-compaction collapse"
assert_no_empty_region_before NEXT_VISIBLE_AFTER_COMPACT "post-compaction collapse"

printf 'ok - Pi %s regular TUI clears viewport-filling tool-result shrink before and after compaction\n' "$(pi --version 2>/dev/null | head -n 1)"
