#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, keyed delivered-decision receipts, terminal-signal dedupe, and the
# working/paused absorb classification that makes routine progress and
# proven-active lifecycle/stale wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files and durable
# markers. The delivered-decision record/consume helpers are explicit stateful
# exceptions shared by fm-send, the watcher, and the daemon.
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew behind an ambiguous lifecycle signal or stale pane is working,
# deliberately paused, or neither. Callers run it ONLY on ambiguous signal
# handling and first sighting of a stale hash, never on every wake, so the
# per-wake triage stays cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. In ordinary active-session mode, an ordinary direct report's
# status-only batch whose every latest event is `working:` is routine progress and
# is absorbed without a runtime busy proof; a persistent secondmate's `working:`
# report keeps its existing delivery because the stale and heartbeat backstops do
# not cover it. Other lines without these verbs are ambiguous signals: the
# watcher absorbs them only with positive provably-working evidence, while the
# daemon uses its away-mode classification. FM_CAPTAIN_RE overrides the whole set
# when a home needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Optional re-surface cadence for an absorbed captain-wait window (a declared
# pause or a verified captain hold). EMPTY means off: absorbed captain-wait
# windows stay silent by default because the captain monitors idle windows
# through Herdr and pull-based digests. Setting FM_PAUSE_RESURFACE_SECS
# explicitly opts back into one recheck wake per window per cadence - far longer
# than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), so an
# opted-in hold still cannot rot invisibly. Both consumers read
# FM_PAUSE_RESURFACE_SECS with this default so the cadence has one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave a crew's endpoint idle, so the
# watcher applies its bounded pause cadence to them regardless of agent
# liveness; only an authoritatively working crew outranks the declaration.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A resolved line may instead carry that token as its exact final note token:
#   resolved: <how it was decided> [key=api-shape]
# For OPENING verbs (needs-decision/blocked) and progress verbs the prefix token
# is authoritative and key-like text elsewhere in note prose is not semantic, so
# a question mentioning another key still opens its own decision. CLOSING verbs
# (resolved, captain-held) parse fail-closed instead: a line carrying more than
# one key-like token is ambiguous about which decision it closes and is rejected,
# keeping the decision open.
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local line=$1 prefix k verb
  line=${line%"${line##*[![:space:]]}"}
  prefix=${line%%:*}
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
      esac
      verb=$(status_line_verb "$line")
      case "$verb" in
        "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}"|"${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}")
          [ "$(decision_key_from_text "$line" 2>/dev/null || true)" = "$k" ] || return 1
          ;;
      esac
      printf '%s' "$k"
      ;;
    *)
      verb=$(status_line_verb "$line")
      case "$verb:$line" in
        "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}:"*\ \[key=*\])
          k=${line##*\[key=}
          k=${k%\]}
          case "$k" in
            ''|*[!A-Za-z0-9._-]*) return 1 ;;
            *)
              [ "$(decision_key_from_text "$line" 2>/dev/null || true)" = "$k" ] || return 1
              printf '%s' "$k"
              ;;
          esac
          ;;
        *) printf 'default' ;;
      esac
      ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
# The scan_open_decisions wrapper below enumerates a whole directory rather than
# a single caller-chosen path, so a status file that is itself a symlink (e.g.
# escaping the state directory) is rejected outright with a plain [ -L ] check
# before any read - a cheap builtin, unlike fm_wake_latest_event's O_NOFOLLOW
# subprocess read, which exists for that function's much narrower payload-driven
# path resolution rather than this directory-local glob.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Return the one explicit decision key token carried by arbitrary delivered
# text. The token grammar is the same slug grammar as status lines above. Text
# with no token, more than one token, or any malformed extra token is rejected,
# so callers never guess which decision a message answered.
decision_key_from_text() {  # <text>
  local text=$1 marker rest key
  marker=$(printf '%s' "$text" | grep -oE '\[key=[A-Za-z0-9._-]+\]' 2>/dev/null | head -1 || true)
  [ -n "$marker" ] || return 1
  rest=${text/"$marker"/}
  case "$rest" in *\[key=*) return 1 ;; esac
  key=${marker#\[key=}; key=${key%\]}
  printf '%s' "$key"
}

status_decision_is_open() {  # <status-file> <key>
  local f=$1 wanted=$2 key rest
  while IFS=$(printf '\t') read -r key rest; do
    [ "$key" = "$wanted" ] && return 0
  done <<EOF
$(status_open_decisions "$f")
EOF
  return 1
}

_fm_decision_identity_valid() {  # <task> <key>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$2" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# Durable task+key receipt written only after fm-send confirms submission of an
# answer carrying exactly one explicit key for a decision still open in that
# task's append-only status stream.
decision_delivery_marker_path() {  # <state> <task> <key>
  local state=$1 task=$2 key=$3
  _fm_decision_identity_valid "$task" "$key" || return 1
  printf '%s/.delivered-decisions/%s/%s' "$state" "$task" "$key"
}

decision_delivery_is_recorded() {  # <state> <task> <key>
  local path
  path=$(decision_delivery_marker_path "$1" "$2" "$3") || return 1
  [ -f "$path" ]
}

decision_delivery_record() {  # <state> <task> <delivered-text>
  local state=$1 task=$2 text=$3 key path dir tmp status lines fingerprint
  key=$(decision_key_from_text "$text") || return 1
  _fm_decision_identity_valid "$task" "$key" || return 1
  status="$state/$task.status"
  status_decision_is_open "$status" "$key" || return 1
  lines=$(awk 'END { print NR + 0 }' "$status" 2>/dev/null) || return 2
  fingerprint=$(cksum < "$status" 2>/dev/null) || return 2
  path=$(decision_delivery_marker_path "$state" "$task" "$key") || return 1
  dir=${path%/*}
  mkdir -p "$dir" || return 2
  chmod 0700 "$state/.delivered-decisions" "$dir" 2>/dev/null || return 2
  tmp=$(mktemp "$dir/.delivery.XXXXXX") || return 2
  if ! { chmod 0600 "$tmp" \
    && printf 'v1\ntask=%s\nkey=%s\nstatus_lines=%s\nstatus_cksum=%s\n' \
      "$task" "$key" "$lines" "$fingerprint" > "$tmp" \
    && mv -f "$tmp" "$path"; }; then
    rm -f "$tmp" 2>/dev/null || true
    return 2
  fi
}

decision_delivery_matches_resolution() {  # <state> <task> <key> <status-file>
  local state=$1 task=$2 key=$3 status=$4 path lines expected actual line verb event_key last seen=""
  path=$(decision_delivery_marker_path "$state" "$task" "$key") || return 1
  [ -f "$path" ] || return 1
  lines=$(grep '^status_lines=' "$path" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  expected=$(grep '^status_cksum=' "$path" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  case "$lines" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$expected" ] || return 1
  actual=$(head -n "$lines" "$status" 2>/dev/null | cksum 2>/dev/null) || return 1
  [ "$actual" = "$expected" ] || return 1
  last=$(last_status_line "$status")
  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(status_line_verb "$line")
    if [ "$verb" = "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}" ]; then
      event_key=$(_fm_decision_key "$line") || return 1
      [ "$event_key" = "$key" ] && [ "$line" = "$last" ] && [ -z "$seen" ] || return 1
      seen=1
    elif status_is_captain_relevant "$line"; then
      return 1
    elif [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]; then
      event_key=$(_fm_decision_key "$line") || return 1
      [ "$event_key" != "$key" ] || return 1
    fi
  done < <(tail -n "+$((lines + 1))" "$status" 2>/dev/null)
  [ -n "$seen" ]
}

decision_delivery_consume() {  # <state> <task> <key>
  local state=$1 task=$2 key=$3 path dir
  path=$(decision_delivery_marker_path "$state" "$task" "$key") || return 1
  [ -f "$path" ] || return 1
  rm -f "$path" || return 1
  dir=${path%/*}
  rmdir "$dir" 2>/dev/null || true
  rmdir "$state/.delivered-decisions" 2>/dev/null || true
}

_fm_status_explicit_decision_key() {  # <status-line>
  local key explicit
  key=$(_fm_decision_key "$1") || return 1
  [ "$key" != default ] || return 1
  explicit=$(decision_key_from_text "$1") || return 1
  [ "$explicit" = "$key" ] || return 1
  printf '%s' "$key"
}

signal_has_resolved_event() {  # <file> ...
  local f last
  for f in "$@"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    [ "$(status_line_verb "$last")" = "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}" ] \
      && return 0
  done
  return 1
}

# 0 only for a complete, unambiguous signal batch consisting of one or more
# explicitly keyed resolved status lines with matching delivered task+key
# receipts, plus optional same-task turn-end markers. Any other file, status
# verb, unmatched key, or unrelated lifecycle marker fails closed.
signal_is_delivered_decision_echo() {  # <state> <file> ...
  local state=$1 f base task last key resolved_tasks="" seen=""
  shift
  for f in "$@"; do
    [ -e "$f" ] || return 1
    base=${f##*/}
    case "$base" in
      *.status)
        task=${base%.status}
        last=$(last_status_line "$f")
        [ "$(status_line_verb "$last")" = "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}" ] \
          || return 1
        key=$(_fm_status_explicit_decision_key "$last") || return 1
        decision_delivery_matches_resolution "$state" "$task" "$key" "$f" || return 1
        case " $resolved_tasks " in *" $task "*) ;; *) resolved_tasks="$resolved_tasks $task" ;; esac
        seen=1
        ;;
      *.turn-ended) : ;;
      *) return 1 ;;
    esac
  done
  [ -n "$seen" ] || return 1
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.turn-ended)
        task=${base%.turn-ended}
        case " $resolved_tasks " in *" $task "*) ;; *) return 1 ;; esac
        ;;
    esac
  done
}

signal_consume_delivered_decision_echo() {  # <state> <file> ...
  local state=$1 f base task last key consumed=""
  shift
  signal_is_delivered_decision_echo "$state" "$@" || return 1
  for f in "$@"; do
    base=${f##*/}
    case "$base" in *.status) ;; *) continue ;; esac
    task=${base%.status}
    last=$(last_status_line "$f")
    key=$(_fm_status_explicit_decision_key "$last") || return 1
    case " $consumed " in *" $task:$key "*) continue ;; esac
    decision_delivery_consume "$state" "$task" "$key" || return 1
    consumed="$consumed $task:$key"
  done
}

_fm_hb_surfaced_path() {  # <state> <task>
  printf '%s/.hb-surfaced-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

# 0 only when the file's events at and after the first occurrence of the
# surfaced line contain no other captain-relevant event. Guards the duplicate
# classifier below against a coalesced batch that appends a never-surfaced
# captain-relevant line (e.g. a new needs-decision) followed by a byte-identical
# re-delivery of the already-surfaced terminal: last-line-only comparison would
# absorb the whole batch and mask the new event.
_fm_status_tail_only_redelivers() {  # <status-file> <surfaced-line>
  local f=$1 surfaced=$2 line matched=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$surfaced" ]; then matched=1; continue; fi
    [ -n "$matched" ] || continue
    status_is_captain_relevant "$line" && return 1
  done < "$f"
  return 0
}

# 0 only when every status in a signal batch is captain-relevant and
# byte-identical to its already-surfaced marker, with optional turn-end markers
# restricted to those same tasks. This is the signal-path twin of terminal stale
# dedupe; a first or changed terminal, unrelated lifecycle marker, mixed
# nonterminal status, or a re-delivery masking a newer captain-relevant event
# remains actionable.
signal_captain_relevant_already_surfaced() {  # <state> <file> ...
  local state=$1 f base task last surfaced_tasks="" seen=""
  shift
  for f in "$@"; do
    [ -e "$f" ] || return 1
    base=${f##*/}
    case "$base" in
      *.status)
        task=${base%.status}
        last=$(last_status_line "$f")
        status_is_captain_relevant "$last" || return 1
        [ "$last" = "$(cat "$(_fm_hb_surfaced_path "$state" "$task")" 2>/dev/null || true)" ] || return 1
        _fm_status_tail_only_redelivers "$f" "$last" || return 1
        case " $surfaced_tasks " in *" $task "*) ;; *) surfaced_tasks="$surfaced_tasks $task" ;; esac
        seen=1
        ;;
      *.turn-ended) : ;;
      *) return 1 ;;
    esac
  done
  [ -n "$seen" ] || return 1
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.turn-ended)
        task=${base%.turn-ended}
        case " $surfaced_tasks " in *" $task "*) ;; *) return 1 ;; esac
        ;;
    esac
  done
}

# Fleet-wide wrapper around status_open_decisions: scans every task's status
# log under <state> and prefixes each still-open decision with its owning task
# id, so a per-wake or per-session surface can print the consolidated open set
# without re-walking the fold itself. A thin directory scan only - the fold
# above remains the ONE place the open/resolved semantics are decided. Prints
# one "<task>\t<key>\t<verb>\t<note>" line per open decision, in glob (task id)
# order; prints nothing when none are open.
scan_open_decisions() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# non-actionable result is NOT "benign" on its own: pure working-progress batches
# are benign by event semantics, while every other signal is benign only when the
# crew is also provably working (signal_crew_provably_working below).
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Task kind recorded in a status file's sibling `<id>.meta`, echoed as one token.
# A metadata record with no kind= field is an ordinary ship task and a status file
# with no metadata at all is unknown, matching bin/fm-watch.sh's window_kind.
status_file_kind() {  # <status-file>
  local f=$1 meta kind
  meta="${f%.status}.meta"
  if [ -f "$meta" ]; then
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s' "${kind:-ship}"
    return 0
  fi
  printf 'unknown'
}

# 0 (routine/absorb) only when the signal batch contains one or more status files,
# contains no lifecycle marker or unknown file shape, references no persistent
# secondmate, and every status file's latest event has the leading `working` verb.
# This is intentionally narrower than "not captain-relevant": paused, resolved,
# captain-held, missing, and malformed signals retain their existing conservative
# reconciliation path.
# A secondmate is excluded because routine absorb relies on the unchanged-pane
# stale path as its delayed backstop, and that path deliberately skips a
# secondmate endpoint unless it declared a pause (an idle secondmate agent is
# healthy by design), while the heartbeat backstop only rescans captain-relevant
# statuses. A secondmate `working [key=...]` line is also its documented sparse
# material phase report and a valid correlated answer to a marked request
# (bin/fm-brief.sh's charter contract, bin/fm-pending-reply-lib.sh), so it keeps
# the conservative provably-working path that used to deliver it.
# The always-on watcher uses this before consulting semantic busy state. Away mode
# does not use it because the daemon remains the sole triage owner there.
signal_is_routine_working_progress() {  # <file> ...
  local f last seen=""
  for f in "$@"; do
    case "$f" in *.status) ;; *) return 1 ;; esac
    [ -e "$f" ] || return 1
    case "$(status_file_kind "$f")" in secondmate) return 1 ;; esac
    last=$(last_status_line "$f")
    [ "$(status_line_verb "$last")" = working ] || return 1
    seen=1
  done
  [ -n "$seen" ]
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on ambiguous signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: an ambiguous signal (a bare turn-end, an
# unknown file shape, a non-working nonterminal event) or a stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). Routine working-progress batches never reach this
# predicate; signal_is_routine_working_progress absorbs them on event semantics
# alone. For stale panes it is checked before trusting the status log so a
# pre-validation captain-relevant line does not override an active run. See
# crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by an ambiguous "signal:" wake is
# provably working; 1 (actionable/surface) if any is not, or no task can be
# resolved. Pure working-progress batches are handled before this predicate.
# Pass the same space-separated file list as signal_reason_is_actionable. Files
# are mapped to task ids by stripping the .status / .turn-ended suffix; a signal
# with nothing provably working must surface, so an empty/unresolvable list
# returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
