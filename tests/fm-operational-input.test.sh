#!/usr/bin/env bash
# Exact current and narrow legacy Firstmate operational-input protocol checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-operational-input.sh"
assert_present "$OWNER" "canonical operational-input owner is missing"

# shellcheck source=/dev/null
. "$OWNER"

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

test_current_envelopes() {
  local kind body encoded parsed recovered prefix_hex
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "operational prefix lost exact U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in watcher turn-end-guard; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "current $kind did not retain its structural kind"
    fm_operational_input_body "$encoded" recovered \
      || fail "could not recover current $kind body"
    [ "$recovered" = "$body" ] \
      || fail "current $kind body changed during encode and parse"
  done
  pass "operational input preserves exact current watcher and guard envelopes"
}

test_away_outer_sentinel() {
  local body inner message parsed recovered first_hex
  body="Supervisor escalate (1 event(s)): done: fixture"
  fm_operational_input_encode away-supervisor "$body" inner \
    || fail "could not encode inner away-supervisor envelope"
  [ "$(kind_cli "$inner")" = away-supervisor ] \
    || fail "exact inner away envelope was not classifiable after Pi removed the control sentinel"
  message="${FM_AFK_SENTINEL}${inner}"
  first_hex=$(printf '%s' "$message" | od -An -tx1 | tr -d ' \n' | cut -c1-2)
  [ "$first_hex" = 1f ] \
    || fail "away operational input lost leading 0x1f: $first_hex"
  fm_operational_input_kind "$message" parsed \
    || fail "leading-sentinel away envelope did not parse"
  [ "$parsed" = away-supervisor ] \
    || fail "leading-sentinel away envelope became $parsed"
  fm_operational_input_body "$message" recovered \
    || fail "could not recover leading-sentinel away body"
  [ "$recovered" = "$body" ] \
    || fail "away body changed during envelope parse"
  pass "away operational input keeps 0x1f first and its semantic body recoverable"
}

test_legacy_shapes_are_narrow() {
  local watcher guard away parsed
  watcher="FIRSTMATE WATCHER WAKE: signal: legacy fixture

Run bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision."
  guard="TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.

watcher: FAILED - legacy fixture"
  away="${FM_AFK_SENTINEL}Supervisor escalate (1 event(s)): done: legacy fixture"

  for fixture in \
    "watcher|$watcher" \
    "turn-end-guard|$guard" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    fm_operational_input_classify "$message" parsed \
      || fail "exact legacy $expected shape was not classified"
    [ "$parsed" = "$expected" ] \
      || fail "exact legacy $expected shape became $parsed"
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected shape leaked into the current parser"
  done
  pass "legacy classification accepts only the fork's exact historical shapes"
}

test_genuine_near_misses_remain_visible() {
  local marker fixture parsed
  marker=$FM_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Captain quote: ${FM_OPERATIONAL_PREFIX}v1 watcher: quoted
FIRSTMATE_OP: v1 watcher: ASCII only
$marker arbitrary captain text
Ordinary captain text before ${FM_OPERATIONAL_PREFIX}v1 watcher: embedded
${FM_OPERATIONAL_PREFIX}v1 unknown: invalid kind
${FM_OPERATIONAL_PREFIX}v1 watcher:
FIRSTMATE WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
EOF
  pass "operational input keeps quoted, malformed, embedded, and broad-substring near misses genuine"
}

test_invalid_current_encodings() {
  local output
  output=$(printf 'body' | "$OWNER" encode unknown 2>/dev/null) \
    && fail "unknown kind was accepted"
  [ -z "$output" ] || fail "unknown kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty body was accepted"
  [ -z "$output" ] || fail "empty body printed protocol data"
  pass "operational input rejects unknown kinds and empty current bodies"
}

# Pi's chat mount path re-classifies every user message on load, resume, thinking
# toggle, and compaction, so .pi/extensions/lib/fm-operational-input.ts mirrors
# this owner in-process instead of spawning it. That mirror is only safe while it
# agrees byte for byte on every accept and reject, so pin it here.
test_pi_mirror_matches_the_shell_owner() {
  local mirror out status
  mirror="$ROOT/.pi/extensions/lib/fm-operational-input.ts"
  assert_present "$mirror" "in-process Pi operational-input mirror is missing"
  command -v node >/dev/null 2>&1 || {
    echo "skip: node not found for the in-process operational-input mirror check"
    return 0
  }

  out=$(MIRROR="$mirror" OWNER="$OWNER" NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const mirror = await import(pathToFileURL(process.env.MIRROR).href);
const owner = process.env.OWNER;
const shell = (command, message, kind) => {
  const args = kind === undefined ? [command] : [command, kind];
  const result = spawnSync(owner, args, { encoding: "utf8", input: message });
  if (result.status !== 0) return undefined;
  return command === "encode" ? result.stdout : result.stdout.replace(/\n$/, "");
};

const mark = mirror.FIRSTMATE_OPERATIONAL_MARK;
const sentinel = mirror.FIRSTMATE_AFK_SENTINEL;
const header = mirror.FIRSTMATE_OPERATIONAL_HEADER_PREFIX;
if (Buffer.from(mark, "utf8").toString("hex") !== "e281a3") {
  throw new Error(`mirror lost the exact U+2063 mark: ${Buffer.from(mark, "utf8").toString("hex")}`);
}
if (Buffer.from(sentinel, "utf8").toString("hex") !== "1f") {
  throw new Error(`mirror lost the exact 0x1f away sentinel: ${Buffer.from(sentinel, "utf8").toString("hex")}`);
}

for (const kind of mirror.FIRSTMATE_CURRENT_OPERATIONAL_KINDS) {
  const body = `MIRROR_BODY_FOR_${kind}`;
  const encoded = mirror.encodeFirstmateOperationalInput(kind, body);
  if (encoded !== shell("encode", body, kind)) {
    throw new Error(`mirror and owner disagree on the ${kind} envelope: ${JSON.stringify(encoded)}`);
  }
}

const watcherLegacy = "FIRSTMATE WATCHER WAKE: signal: legacy fixture\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.";
const guardLegacy = "TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.\n\nwatcher: FAILED - legacy fixture";
const fixtures = [
  mirror.encodeFirstmateOperationalInput("watcher", "signal: fixture"),
  mirror.encodeFirstmateOperationalInput("turn-end-guard", "guard fixture"),
  sentinel + mirror.encodeFirstmateOperationalInput("away-supervisor", "escalate fixture"),
  mirror.encodeFirstmateOperationalInput("away-supervisor", "escalate fixture"),
  watcherLegacy,
  guardLegacy,
  `${sentinel}Supervisor escalate (1 event(s)): done: legacy fixture`,
  `Captain quote: ${header}watcher: quoted`,
  "FIRSTMATE_OP: v1 watcher: ASCII only",
  `${mark} arbitrary captain text`,
  `Ordinary captain text before ${header}watcher: embedded`,
  `${header}unknown: invalid kind`,
  `${header}watcher:`,
  `${header}watcher: `,
  "FIRSTMATE WATCHER WAKE: can you explain this phrase?",
  "TURN WOULD END BLIND - can you make this warning friendlier?",
  "Supervisor escalate (1 event(s)): is this wording clear?",
  watcherLegacy.replace("signal: legacy fixture", ""),
  guardLegacy.slice(0, guardLegacy.indexOf("watcher: FAILED")),
];
for (const fixture of fixtures) {
  const mirrorClassify = mirror.classifyFirstmateOperationalText(fixture) ?? "";
  const ownerClassify = shell("classify", fixture) ?? "";
  if (mirrorClassify !== ownerClassify) {
    throw new Error(`classify drift on ${JSON.stringify(fixture)}: mirror=${mirrorClassify} owner=${ownerClassify}`);
  }
  const mirrorKind = mirror.classifyFirstmateCurrentOperationalText(fixture) ?? "";
  const ownerKind = shell("kind", fixture) ?? "";
  if (mirrorKind !== ownerKind) {
    throw new Error(`kind drift on ${JSON.stringify(fixture)}: mirror=${mirrorKind} owner=${ownerKind}`);
  }
}

let refused = false;
try {
  mirror.encodeFirstmateOperationalInput("watcher", "");
} catch {
  refused = true;
}
if (!refused) throw new Error("mirror accepted an empty current body");
if (mirror.encodeFirstmateOperationalInputOrPlain("watcher", "") !== "") {
  throw new Error("degraded encode did not fall back to the plain message");
}
JS
)
  status=$?
  expect_code 0 "$status" "in-process Pi mirror must match the shell owner: $out"
  [ -z "$out" ] || fail "operational-input mirror check printed output: $out"
  pass "in-process Pi operational-input mirror matches the shell owner exactly"
}

test_current_envelopes
test_away_outer_sentinel
test_legacy_shapes_are_narrow
test_genuine_near_misses_remain_visible
test_invalid_current_encodings
test_pi_mirror_matches_the_shell_owner
