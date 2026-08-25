#!/usr/bin/env bash
# End-user demo of the Pi follow-up aggregator: what a Firstmate primary running
# on Pi actually receives when its watcher closes several times in a row.
# Uses the real .pi/extensions/fm-primary-pi-watch.ts, a real config/wake-batch-seconds
# override, and a fake fm-watch-arm.sh that emits the wake lines a live watcher emits.
set -u
ROOT=${1:?usage: pi-wake-aggregator-demo.sh <repo-root>}
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pi-wake-demo.XXXXXX")
# Reuse the suite's fixture installer verbatim so the demo runs the production extension.
start=$(grep -n '^install_pi_watch_extension_fixture()' "$ROOT/tests/fm-pi-watch-extension.test.sh" | cut -d: -f1)
end=$(( $(grep -n '^test_pi_extension_reports_external_healthy_watcher()' "$ROOT/tests/fm-pi-watch-extension.test.sh" | cut -d: -f1) - 1 ))
sed -n "${start},${end}p" "$ROOT/tests/fm-pi-watch-extension.test.sh" > "$TMP_ROOT/installer.sh"
# shellcheck disable=SC1090
. "$TMP_ROOT/installer.sh"
export NODE_NO_WARNINGS=1

repo="$TMP_ROOT/repo"; home="$TMP_ROOT/home"; log="$TMP_ROOT/arm.log"; stop="$TMP_ROOT/stop"
mkdir -p "$repo/bin" "$home/state" "$home/config"
install_pi_watch_extension_fixture "$repo"
printf 'working: rebasing branch\n' > "$home/state/alpha.status"
printf 'done: PR https://example.test/pr/12\n' > "$home/state/bravo.status"
printf 'blocked [key=deploy-window]: captain decision required\n' > "$home/state/charlie.status"
# The home-local aggregation window (production default is 60s; 3s keeps the demo watchable).
printf '3\n' > "$home/config/wake-batch-seconds"
echo "captain's config/wake-batch-seconds = $(cat "$home/config/wake-batch-seconds")   (production default: 60)"
echo

run_scenario() {  # <title> <urgent:0|1>
  local title=$1 urgent=$2 log="$TMP_ROOT/arm-$2.log" stop="$TMP_ROOT/stop-$2"
  echo "================================================================"
  echo "$title"
  echo "================================================================"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then printf 'confirmed\n' >> "\${FM_ARM_LOG:?}"; exit 0; fi
printf 'arm\n' >> "\${FM_ARM_LOG:?}"
count=\$(grep -c '^arm\$' "\$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=demo-%s\n' "\$\$" "\$count"
case "\$count" in
  1) printf 'signal: %s/state/alpha.status\n' "\$FM_HOME" ;;
  2) sleep 0.2; printf 'signal: %s/state/alpha.status\n' "\$FM_HOME" ;;
  3) sleep 0.2; printf 'stale: w1:crew-bravo (paused awaiting upstream release)\n' ;;
  4) sleep 0.2; printf 'signal: %s/state/bravo.status\n' "\$FM_HOME" ;;
  5) sleep 0.2
     if [ "$urgent" = 1 ]; then printf 'signal: %s/state/charlie.status\n' "\$FM_HOME"
     else trap 'exit 0' TERM INT; while [ ! -e "\$FM_STOP_FILE" ]; do sleep 0.05; done
     fi ;;
  *) trap 'exit 0' TERM INT; while [ ! -e "\$FM_STOP_FILE" ]; do sleep 0.05; done ;;
esac
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
    FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module <<'EOF'
import { writeFileSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let tool = null;
const start = Date.now();
const pi = {
  on() {}, registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage: async (content) => {
    const at = ((Date.now() - start) / 1000).toFixed(1);
    console.log(`--- Pi primary received a follow-up at t+${at}s ---`);
    console.log(content.replace(new RegExp(process.env.FM_HOME, "g"), "$FM_HOME"));
    console.log("");
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
console.log("primary arms its watcher; the watcher closes several times within ~1s");
console.log("");
await tool.execute("demo", {}, undefined, undefined, {});
await new Promise((r) => setTimeout(r, 7000));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
console.log(`watcher closes seen: ${rows.filter((r) => r === "arm").length - 1}; follow-ups delivered to the primary: see above; delivery acknowledgements sent back to the watcher: ${rows.filter((r) => r === "confirmed").length}`);
console.log("");
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
}

run_scenario "SCENARIO A - routine wakes only (working:/done:/paused stale): held for the 3s window, deduplicated, delivered once" 0
run_scenario "SCENARIO B - same routine wakes plus one blocked [key=deploy-window] status: urgent bypasses the window" 1

rm -rf "$TMP_ROOT"
