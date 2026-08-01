#!/usr/bin/env bash
# Focused deterministic persistence, renderer, layout, and working-boat checks for /calm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-calm-pi-extension)
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
OPERATIONAL_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
PI_OPERATIONAL_INPUT="$ROOT/.pi/extensions/lib/fm-operational-input.ts"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

[ -f "$ROOT/.pi/extensions/fm-calm.ts" ] \
  || fail "tracked Pi Calm extension is missing"
[ -f "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" ] \
  || fail "tracked Calm visibility owner is missing"
[ -f "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" ] \
  || fail "tracked Calm assistant-layout owner is missing"
[ -f "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" ] \
  || fail "tracked Calm working-ship owner is missing"
[ -f "$OPERATIONAL_LAYOUT" ] \
  || fail "tracked Calm operational-user layout owner is missing"
[ -f "$PI_OPERATIONAL_INPUT" ] \
  || fail "tracked Pi operational-input adapter is missing"
[ -f "$OPERATIONAL_INPUT" ] \
  || fail "tracked operational-input owner is missing"
[ -f "$PI_PACKAGE_DIR/package.json" ] \
  || fail "installed Pi package is required for deterministic Calm verification"

fixture="$TMP_ROOT/fixture"
mkdir -p "$fixture/lib" "$fixture/home/config" "$fixture/node_modules/@earendil-works"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$fixture/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$fixture/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$fixture/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$fixture/lib/fm-calm-working-ship.ts"
cp "$OPERATIONAL_LAYOUT" "$fixture/lib/fm-calm-operational-user-layout.ts"
cp "$PI_OPERATIONAL_INPUT" "$fixture/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

out=$(cd "$fixture" && \
  EXT="$fixture/fm-calm.ts" \
  VISIBILITY="$fixture/lib/fm-calm-visibility.ts" \
  SHIP="$fixture/lib/fm-calm-working-ship.ts" \
  FM_HOME="$fixture/home" \
  FM_OPERATIONAL_INPUT_SCRIPT="$OPERATIONAL_INPUT" \
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  NODE_NO_WARNINGS=1 \
  node --input-type=module 2>&1 <<'JS'
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const extensionUrl = `${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`;
const visibilityUrl = pathToFileURL(process.env.VISIBILITY).href;
const shipUrl = `${pathToFileURL(process.env.SHIP).href}?test=${Date.now()}`;
const extension = await import(extensionUrl);
const visibility = await import(visibilityUrl);
const ship = await import(shipUrl);
const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ Container, visibleWidth }, { initTheme, theme }, { AssistantMessageComponent, InteractiveMode, UserMessageComponent }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import("@earendil-works/pi-coding-agent"),
]);
initTheme("dark");

const check = (condition, message) => {
  if (!condition) throw new Error(message);
};
const stripAnsi = (text) => text.replace(/\u001b\[[0-9;]*m/g, "");

function register(extensionModule = extension) {
  const handlers = new Map();
  const tools = [];
  let command;
  const emitted = [];
  const pi = {
    events: {
      emit(name, state) { emitted.push({ name, state }); },
      on() {},
    },
    on(name, handler) { handlers.set(name, handler); },
    registerCommand(name, value) { if (name === "calm") command = value; },
    registerEntryRenderer() {},
    registerTool(tool) { tools.push(tool); },
  };
  extensionModule.default(pi);
  check(command, "Calm command was not registered");
  check(handlers.has("session_start"), "Calm session_start handler was not registered");
  check(!handlers.has("input"), "Calm registered a semantic input interceptor");
  return { command, emitted, handlers, tools };
}

function context() {
  const state = {
    expanded: true,
    editorText: "",
    hiddenThinkingLabel: "unset",
    terminalHandler: undefined,
    workingVisible: [],
    widgets: [],
  };
  return {
    state,
    ui: {
      getEditorText: () => state.editorText,
      getToolsExpanded: () => state.expanded,
      onTerminalInput: (handler) => {
        state.terminalHandler = handler;
        return () => { if (state.terminalHandler === handler) state.terminalHandler = undefined; };
      },
      setHiddenThinkingLabel: (value) => { state.hiddenThinkingLabel = value; },
      setStatus() {},
      setToolsExpanded: (value) => { state.expanded = value; },
      setWidget: (key, value) => { state.widgets.push({ key, value }); },
      setWorkingVisible: (value) => { state.workingVisible.push(value); },
    },
  };
}

const preference = `${process.env.FM_HOME}/config/calm`;
rmSync(preference, { force: true });
let calm = register();
let ctx = context();
calm.handlers.get("session_start")({ reason: "startup" }, ctx);
check(calm.emitted.at(-1).state.active === false, "absent preference did not default off");
check(ctx.state.workingVisible.at(-1) === true, "Calm off did not restore stock working visibility");

writeFileSync(preference, "garbage\n");
calm = register();
ctx = context();
calm.handlers.get("session_start")({ reason: "startup" }, ctx);
check(calm.emitted.at(-1).state.active === false, "malformed preference did not default off");

rmSync(preference, { force: true });
mkdirSync(preference);
calm = register();
ctx = context();
calm.handlers.get("session_start")({ reason: "startup" }, ctx);
check(calm.emitted.at(-1).state.active === false, "unreadable preference did not default off");
rmSync(preference, { recursive: true, force: true });

calm = register();
ctx = context();
calm.handlers.get("session_start")({ reason: "startup" }, ctx);
await calm.command.handler("", ctx);
check(readFileSync(preference, "utf8") === "on\n", "toggle did not persist exact on value");
check(calm.emitted.at(-1).state.active === true, "toggle did not activate live presentation");
check(ctx.state.expanded === true, "toggle changed Ctrl+O expansion state");
await calm.command.handler("", ctx);
check(readFileSync(preference, "utf8") === "off\n", "second toggle did not persist exact off value");
check(calm.emitted.at(-1).state.active === false, "second toggle did not restore live presentation");

writeFileSync(preference, "off\n");
const stable = register();
const stableCtx = context();
stable.handlers.get("session_start")({ reason: "startup" }, stableCtx);
process.env.FM_CONFIG_OVERRIDE = "/dev/null";
const failingExtension = await import(`${pathToFileURL(process.env.EXT).href}?write-failure=${Date.now()}`);
const failing = register(failingExtension);
const failingCtx = context();
failing.handlers.get("session_start")({ reason: "startup" }, failingCtx);
let failed = false;
try {
  await failing.command.handler("", failingCtx);
} catch {
  failed = true;
}
delete process.env.FM_CONFIG_OVERRIDE;
check(failed, "atomic preference failure did not surface");
check(failing.emitted.at(-1).state.active === false, "failed atomic write changed live state");
check(readFileSync(preference, "utf8") === "off\n", "failed atomic write changed prior preference");
check(!readdirSync(`${process.env.FM_HOME}/config`).some((name) => name.includes(".tmp")), "failed atomic write left a temporary file");

calm = register();
ctx = context();
calm.handlers.get("session_start")({ reason: "startup" }, ctx);
await calm.command.handler("", ctx);
ctx.state.editorText = "/export calm.html";
ctx.state.terminalHandler("\r");
check(calm.emitted.at(-1).state.stockExportRendering === true, "export did not temporarily restore stock rendering");
await new Promise((resolve) => setTimeout(resolve, 0));
check(calm.emitted.at(-1).state.stockExportRendering === false, "export did not restore Calm rendering");
check(ctx.state.expanded === true, "export redraw changed Ctrl+O expansion state");
ctx.state.editorText = "/share";
ctx.state.terminalHandler("\r");
check(calm.emitted.at(-1).state.stockExportRendering === true, "share did not temporarily restore stock rendering");
await new Promise((resolve) => setTimeout(resolve, 0));
check(ctx.state.expanded === true, "share redraw changed Ctrl+O expansion state");

const operationalInput = await import(`${pathToFileURL(`${process.cwd()}/lib/fm-operational-input.ts`).href}?test=${Date.now()}`);
const watcherBody = "FIRSTMATE WATCHER WAKE: signal: exact fixture\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.";
const watcherMessage = operationalInput.encodeFirstmateOperationalInput("watcher", watcherBody);
const history = [];
const chat = {
  children: [],
  addChild(component) { this.children.push(component); },
};
const mode = {
  chatContainer: chat,
  editor: { addToHistory: (text) => history.push(text) },
  getMarkdownThemeWithSettings: () => undefined,
  getUserMessageText: (message) => typeof message.content === "string"
    ? message.content
    : message.content.filter((item) => item.type === "text").map((item) => item.text).join(""),
  outputPad: 1,
};
InteractiveMode.prototype.addMessageToChat.call(
  mode,
  { role: "user", content: watcherMessage },
  { populateHistory: true },
);
check(chat.children.length === 1, "operational user row was not mounted once");
check(chat.children[0].render(100).length === 0, "Calm on left operational user-row geometry");
check(history.length === 1 && history[0] === watcherMessage, "operational row lost exact semantic history content");
const nearMissChat = {
  children: [],
  addChild(component) { this.children.push(component); },
};
InteractiveMode.prototype.addMessageToChat.call(
  { ...mode, chatContainer: nearMissChat },
  { role: "user", content: `Captain quote: ${watcherMessage}` },
);
check(nearMissChat.children.length === 1, "genuine near-miss row was not mounted");
check(nearMissChat.children[0].render(100).join("\n").includes("Captain quote"), "Calm hid a genuine operational near miss");
const imageNearMissChat = {
  children: [],
  addChild(component) { this.children.push(component); },
};
InteractiveMode.prototype.addMessageToChat.call(
  { ...mode, chatContainer: imageNearMissChat },
  {
    role: "user",
    content: [
      { type: "text", text: watcherMessage },
      { type: "image", data: "fixture", mimeType: "image/png" },
    ],
  },
);
check(imageNearMissChat.children.length === 1, "image-bearing operational near miss was not mounted");
check(imageNearMissChat.children[0].render(100).length > 0, "Calm hid an image-bearing operational near miss");
await calm.command.handler("", ctx);
const stockOperational = new UserMessageComponent(watcherMessage, undefined, 1);
check(chat.children[0].render(100).join("\n") === stockOperational.render(100).join("\n"), "Calm off did not restore stock operational rendering");

check(calm.tools.map((tool) => tool.name).join(",") === "read,bash,edit,write,grep,find,ls", "built-in wrapper set drifted");
const tool = calm.tools[0];
const renderContext = { cwd: process.cwd(), state: {}, isPartial: false, isError: false };
visibility.setCalmPresentation(true);
const hiddenCall = tool.renderCall({}, theme, renderContext);
check(hiddenCall instanceof Container && hiddenCall.render(80).length === 0, "Calm on did not zero built-in call geometry");
const hiddenResult = tool.renderResult({ content: [{ type: "text", text: "hidden" }] }, { expanded: false }, theme, renderContext);
check(hiddenResult instanceof Container && hiddenResult.render(80).length === 0, "Calm on did not zero built-in result geometry");
visibility.setCalmPresentation(false);
check(tool.renderCall({}, theme, renderContext).render(80).length > 0, "Calm off did not restore built-in rendering");

const thinkingMessage = {
  role: "assistant",
  api: "calm-test",
  provider: "calm-test",
  model: "deterministic",
  usage: {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  },
  content: [{ type: "thinking", thinking: "HIDDEN_THINKING" }],
  stopReason: "stop",
  timestamp: 1,
};
const thinking = new AssistantMessageComponent(thinkingMessage, true);
check(thinking.render(80).length > 0, "stock collapsed thinking fixture had no geometry");
thinking.setHiddenThinkingLabel("");
visibility.setCalmPresentation(true);
thinking.updateContent(thinkingMessage);
check(thinking.render(80).length === 0, "Calm collapsed thinking retained geometry");
visibility.setCalmPresentation(false);
thinking.setHiddenThinkingLabel("Thinking...");
thinking.updateContent(thinkingMessage);
check(thinking.render(80).length > 0, "Calm off did not restore collapsed thinking geometry");

const animation = ship.createCalmWorkingShipAnimation();
check(ship.CALM_WORKING_SHIP_TICK_MS === 220, "water cadence changed");
check(ship.CALM_WORKING_SHIP_TICKS_PER_MOVE === 4, "boat cadence changed");
let frame = animation.render(30);
check(frame.length === 2, "wide boat did not render two rows");
check(frame.every((row) => visibleWidth(row) <= 30), "wide boat exceeded terminal width");
const start = animation.position();
for (let index = 0; index < 3; index += 1) animation.tick();
check(animation.position() === start, "boat moved before 880ms cadence");
animation.tick();
check(animation.position() === start + 1, "boat did not move at 880ms cadence");
frame = animation.render(3);
check(frame.length === 1 && visibleWidth(frame[0]) === 3, "narrow boat fallback geometry changed");
animation.render(30);
for (let index = 0; index < 200; index += 1) {
  animation.tick();
  animation.render(30);
}
check(Math.abs(animation.direction()) === 1, "boat direction became invalid after bounce");
const frozenPosition = animation.position();
const frozenDirection = animation.direction();
const widget = ship.createCalmWorkingShipWidget({ requestRender() {} }, animation);
widget.render(30);
widget.dispose();
check(widget.render(30).length === 0, "disposed boat widget still rendered");
check(animation.position() === frozenPosition && animation.direction() === frozenDirection, "disposing boat lost continuity");
animation.clampToWidth(6);
check(animation.position() <= 2 && Math.abs(animation.direction()) === 1, "hidden resize did not clamp frozen boat");
animation.reset();
check(animation.position() === 0 && animation.direction() === 1 && animation.waterPhase() === 0, "fresh session reset drifted");
check(stripAnsi(animation.render(1)[0]).length === 1, "one-column fallback drifted");

check(existsSync(preference), "preference disappeared during deterministic checks");
JS
)
status=$?
[ "$status" -eq 0 ] || fail "Pi Calm deterministic core failed: $out"
[ -z "$out" ] || fail "Pi Calm deterministic core printed output: $out"

pass "Pi Calm core preserves persistence, stock-off rendering, built-in geometry, Ctrl+O state, and boat lifecycle"

degraded="$TMP_ROOT/degraded"
mkdir -p "$degraded/lib" "$degraded/node_modules/@earendil-works"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$degraded/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$degraded/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$degraded/lib/fm-calm-working-ship.ts"
cp "$OPERATIONAL_LAYOUT" "$degraded/lib/fm-calm-operational-user-layout.ts"
cp "$PI_OPERATIONAL_INPUT" "$degraded/lib/fm-operational-input.ts"
cat >"$degraded/lib/fm-calm-assistant-layout.ts" <<'TS'
export function installCalmAssistantLayout(): void {
  throw new Error("probe seam missing");
}
TS
ln -s "$PI_PACKAGE_DIR" "$degraded/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$degraded/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$degraded/node_modules/typebox"
printf '%s\n' '{"type":"module"}' >"$degraded/package.json"

out=$(cd "$degraded" && FM_OPERATIONAL_INPUT_SCRIPT="$OPERATIONAL_INPUT" NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import extension from "./fm-calm.ts";
let calmCommand;
extension({
  events: { emit() {}, on() {} },
  on() {},
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  registerEntryRenderer() {},
  registerTool() {},
});
if (!calmCommand) throw new Error("adapter failure disabled the Calm command");
JS
)
status=$?
[ "$status" -eq 0 ] || fail "degraded Calm adapter disabled the extension: $out"
printf '%s\n' "$out" | grep -Fq "Firstmate Calm: collapsed-thinking presentation adapter unavailable, skipping. probe seam missing" \
  || fail "degraded Calm adapter did not emit its named diagnostic: $out"
pass "Pi Calm names and independently skips an unavailable collapsed-thinking adapter"

degraded_op="$TMP_ROOT/degraded-operational"
mkdir -p "$degraded_op/lib" "$degraded_op/node_modules/@earendil-works"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$degraded_op/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$degraded_op/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$degraded_op/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$degraded_op/lib/fm-calm-working-ship.ts"
cat >"$degraded_op/lib/fm-calm-operational-user-layout.ts" <<'TS'
export function installCalmOperationalUserLayout(): void {
  throw new Error("operational probe seam missing");
}
TS
ln -s "$PI_PACKAGE_DIR" "$degraded_op/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$degraded_op/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$degraded_op/node_modules/typebox"
printf '%s\n' '{"type":"module"}' >"$degraded_op/package.json"

out=$(cd "$degraded_op" && NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import extension from "./fm-calm.ts";
let calmCommand;
extension({
  events: { emit() {}, on() {} },
  on() {},
  registerCommand(name, command) { if (name === "calm") calmCommand = command; },
  registerEntryRenderer() {},
  registerTool() {},
});
if (!calmCommand) throw new Error("operational adapter failure disabled the Calm command");
JS
)
status=$?
[ "$status" -eq 0 ] || fail "degraded operational adapter disabled the extension: $out"
printf '%s\n' "$out" | grep -Fq "Firstmate Calm: operational-user-row presentation adapter unavailable, skipping. operational probe seam missing" \
  || fail "degraded operational adapter did not emit its named diagnostic: $out"
pass "Pi Calm names and independently skips an unavailable operational-user-row adapter"
