#!/usr/bin/env bash
# Firstmate's durable Lavish review entry point.
#
# Usage:
#   fm-lavish.sh open <artifact.html>
#
# The artifact must already live at a stable path under
#   $FM_HOME/data/<review-id>/.lavish/<name>.html
# so the review survives disposal of any crewmate worktree.
#
# open launches the browser only on the first successful call for that exact
# canonical artifact. It records the open beside the artifact, and every later
# call re-ensures the same Lavish session with --no-open. Updating the same HTML
# file normally needs no command because Lavish live-reloads the existing tab.
# Temporary, scratch, and out-of-home artifacts are refused before lavish-axi
# runs. Copy their content to the durable convention above instead.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-lavish-lib.sh
. "$SCRIPT_DIR/fm-lavish-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

cmd_open() {
  local artifact=${1-} real id marker marker_value tmp
  [ -n "$artifact" ] || usage
  real=$(fm_lavish_require_durable_artifact "$artifact") || exit 1
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(fm_lavish_artifact_id "$real") || die "cannot derive the Lavish artifact identity"
  marker="$(dirname "$real")/.fm-opened-$id"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || die "unsafe Lavish open marker: $marker"
    marker_value=$(sed -n '1p' "$marker")
    [ "$marker_value" = "$real" ] || die "Lavish open marker does not match its artifact: $marker"
    lavish-axi "$real" --no-open
    return
  fi
  lavish-axi "$real" || exit 1
  tmp="$marker.tmp.$$"
  (umask 077; printf '%s\n' "$real" > "$tmp") || die "cannot stage the Lavish open marker"
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the Lavish open marker"; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; die "cannot publish the Lavish open marker"; }
}

case "${1-}" in
  open) shift; cmd_open "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
