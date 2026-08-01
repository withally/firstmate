// In-process mirror of the wire form owned by bin/fm-operational-input.sh.
//
// Classification sits on Pi's chat mount path, which re-runs for every user
// message on session load, resume, thinking toggle, and compaction, so it must
// stay a constant-prefix string match rather than a subprocess. Construction
// feeds the watcher wake and the turn-end guard follow-up, so it must have no
// failure mode a supervision-critical message can be dropped through.
//
// bin/fm-operational-input.sh stays the protocol owner; tests/fm-operational-input.test.sh
// pins these constants and every accept/reject decision against it so the two
// cannot drift. Matching is exact: a quoted, embedded, malformed, or
// unknown-kind near miss stays a genuine captain message.
export const FIRSTMATE_OPERATIONAL_MARK = "\u2063";
export const FIRSTMATE_AFK_SENTINEL = "\u001f";
export const FIRSTMATE_OPERATIONAL_PREFIX = `${FIRSTMATE_OPERATIONAL_MARK}FIRSTMATE_OP: `;
export const FIRSTMATE_OPERATIONAL_VERSION = "v1";
export const FIRSTMATE_OPERATIONAL_HEADER_PREFIX = `${FIRSTMATE_OPERATIONAL_PREFIX}${FIRSTMATE_OPERATIONAL_VERSION} `;

export const FIRSTMATE_CURRENT_OPERATIONAL_KINDS = [
  "watcher",
  "turn-end-guard",
  "away-supervisor",
] as const;

export type FirstmateCurrentOperationalKind =
  (typeof FIRSTMATE_CURRENT_OPERATIONAL_KINDS)[number];

// Historical payloads are isolated here and are never accepted by the current parser.
const LEGACY_WATCHER_PREFIX = "FIRSTMATE WATCHER WAKE: ";
const LEGACY_WATCHER_SUFFIX =
  "\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.";
const LEGACY_TURNEND_PREFIX =
  "TURN WOULD END BLIND - supervision is off. " +
  "Resume supervision according to the session-start operating block before ending the turn.\n\n";
const LEGACY_AWAY_PREFIX = `${FIRSTMATE_AFK_SENTINEL}Supervisor escalate (`;

function isCurrentKind(candidate: string): candidate is FirstmateCurrentOperationalKind {
  return (FIRSTMATE_CURRENT_OPERATIONAL_KINDS as readonly string[]).includes(candidate);
}

function genericOperationalKind(
  message: string,
): FirstmateCurrentOperationalKind | undefined {
  if (!message.startsWith(FIRSTMATE_OPERATIONAL_HEADER_PREFIX)) return undefined;
  const remainder = message.slice(FIRSTMATE_OPERATIONAL_HEADER_PREFIX.length);
  const separator = remainder.indexOf(": ");
  if (separator < 0) return undefined;
  const candidate = remainder.slice(0, separator);
  if (!isCurrentKind(candidate)) return undefined;
  if (!remainder.slice(separator + 2)) return undefined;
  return candidate;
}

function legacyOperationalKind(
  message: string,
): FirstmateCurrentOperationalKind | undefined {
  if (message.startsWith(LEGACY_AWAY_PREFIX)) return "away-supervisor";
  if (
    message.startsWith(LEGACY_WATCHER_PREFIX) &&
    message.endsWith(LEGACY_WATCHER_SUFFIX) &&
    message.length > LEGACY_WATCHER_PREFIX.length + LEGACY_WATCHER_SUFFIX.length
  ) {
    return "watcher";
  }
  if (
    message.length > LEGACY_TURNEND_PREFIX.length &&
    message.startsWith(LEGACY_TURNEND_PREFIX)
  ) {
    return "turn-end-guard";
  }
  return undefined;
}

export function encodeFirstmateOperationalInput(
  kind: FirstmateCurrentOperationalKind,
  content: string,
): string {
  if (!isCurrentKind(kind) || !content) {
    throw new Error(`could not encode Firstmate operational input kind ${kind}`);
  }
  return `${FIRSTMATE_OPERATIONAL_HEADER_PREFIX}${kind}: ${content}`;
}

// Presentation-only degradation for the supervision-critical watcher wake and
// turn-end guard follow-up: an unencodable message is still delivered plain
// rather than dropped, because delivery matters more than its Calm row class.
export function encodeFirstmateOperationalInputOrPlain(
  kind: FirstmateCurrentOperationalKind,
  content: string,
): string {
  try {
    return encodeFirstmateOperationalInput(kind, content);
  } catch {
    return content;
  }
}

export function classifyFirstmateOperationalText(
  content: string,
): FirstmateCurrentOperationalKind | undefined {
  return (
    classifyFirstmateCurrentOperationalText(content) ?? legacyOperationalKind(content)
  );
}

export function classifyFirstmateCurrentOperationalText(
  content: string,
): FirstmateCurrentOperationalKind | undefined {
  if (content.startsWith(FIRSTMATE_AFK_SENTINEL)) {
    const inner = genericOperationalKind(content.slice(FIRSTMATE_AFK_SENTINEL.length));
    return inner === "away-supervisor" ? inner : undefined;
  }
  return genericOperationalKind(content);
}
