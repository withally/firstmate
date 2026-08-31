#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --authority prints the resolved merge-authority tier instead: captain,
# firstmate, or self. An explicit registry field wins; when absent, legacy
# +yolo maps to self and yolo-off maps to captain.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off / captain
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off / captain
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on / self
#   - <name> [<mode> merge-authority=firstmate] ...    -> <mode> off / firstmate
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo is the compatibility projection of merge authority: self maps to on,
#   while captain and firstmate map to off (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw] [--authority] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
AUTHORITY_ONLY=0
while [ "${1:-}" = "--raw" ] || [ "${1:-}" = "--authority" ]; do
  case "$1" in
    --raw) RAW=1 ;;
    --authority) AUTHORITY_ONLY=1 ;;
  esac
  shift
done
NAME=${1:?usage: fm-project-mode.sh [--raw] [--authority] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  if [ "$AUTHORITY_ONLY" -eq 1 ]; then echo captain; else echo "no-mistakes off"; fi
  exit 0
fi

# awk emits "<mode> <yolo> <explicit-authority>" or nothing if absent.
parsed=$(awk -v n="$NAME" '
  function invalid(kind, value) {
    print kind (value == "" ? "" : " " value)
    exit
  }
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; authority="";
    if (NF < 3) invalid("__malformed_annotation__", "")
    if ($3 == "-") {
      print mode, yolo, authority; exit
    }
    if ($3 !~ /^\[/) invalid("__malformed_annotation__", "")
    s=""; closed=0;
    for (i=3; i<=NF; i++) {
      s = s (s==""?"":" ") $i
      if ($i ~ /\]$/) { closed=1; break }
    }
    closed || invalid("__malformed_annotation__", "")
    sub(/^\[/, "", s); sub(/\]$/, "", s)
    k = split(s, a, " ")
    if (a[1] == "") invalid("__malformed_annotation__", "")
    if (a[1] == "+yolo") {
      yolo="on"; seen_yolo=1
    } else if (a[1] ~ /^merge-authority=/) {
      invalid("__malformed_annotation__", "")
    } else {
      mode=a[1]
    }
    for (j=2; j<=k; j++) {
      if (a[j] == "+yolo") {
        seen_yolo++
        if (seen_yolo > 1) invalid("__duplicate_annotation__", "yolo")
        yolo="on"
      } else if (a[j] ~ /^merge-authority=/) {
        seen_authority++
        if (seen_authority > 1) invalid("__duplicate_annotation__", "merge-authority")
        authority=a[j]; sub(/^merge-authority=/, "", authority)
        if (authority !~ /^(captain|firstmate|self)$/) invalid("__unknown_annotation__", "merge-authority")
      } else {
        invalid("__unknown_annotation__", a[j])
      }
    }
    if (mode !~ /^(no-mistakes|direct-PR|local-only|no-mistakes-prod-only)$/)
      invalid("__unknown_mode__", mode)
    print mode, yolo, authority; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  if [ "$AUTHORITY_ONLY" -eq 1 ]; then echo captain; else echo "no-mistakes off"; fi
  exit 0
fi

case "$parsed" in
  __malformed_annotation__|__duplicate_annotation__*|__unknown_annotation__*)
    echo "warn: malformed registry annotation for $NAME; defaulting to no-mistakes off with captain authority" >&2
    parsed="no-mistakes off captain"
    ;;
  __unknown_mode__\ *)
    mode=${parsed#__unknown_mode__ }
    echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2
    parsed="no-mistakes off captain"
    ;;
esac

mode=${parsed%% *}
rest=${parsed#* }
yolo=${rest%% *}
authority=${rest#* }
[ "$authority" != "$rest" ] || authority=
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; authority=captain ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ -z "$authority" ]; then
  if [ "$yolo" = on ]; then authority=self; else authority=captain; fi
else
  case "$authority" in
    captain|firstmate|self) ;;
    *)
      echo "warn: unknown merge authority \"$authority\" for $NAME; defaulting to captain" >&2
      authority=captain
      yolo=off
      ;;
  esac
  if [ "$yolo" = on ] && [ "$authority" != self ]; then
    echo "warn: conflicting merge authority and +yolo posture for $NAME; defaulting to captain" >&2
    authority=captain
    yolo=off
  elif [ "$authority" = self ]; then
    yolo=on
  else
    yolo=off
  fi
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
if [ "$AUTHORITY_ONLY" -eq 1 ]; then
  echo "$authority"
else
  echo "$mode $yolo"
fi
