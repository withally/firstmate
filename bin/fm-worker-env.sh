#!/usr/bin/env bash
# Launch one worker process with a deliberately bounded environment.
# Usage: fm-worker-env.sh <allowlist-file> <command> [<arg>...]
#        fm-worker-env.sh <allowlist-file> --shell-command <command-string>
#
# The optional allowlist file contains one exact environment variable name per
# line. Blank lines and lines beginning with # are ignored. An invalid name or
# unreadable existing file fails closed. Allowlisted names override the default
# secret-name deny rule.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 2 ] || { usage >&2; exit 2; }

ALLOWLIST=$1
shift

SHELL_COMMAND=
if [ "${1:-}" = --shell-command ]; then
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  SHELL_COMMAND=$2
fi

ALLOWED=()
ALLOWED_COUNT=0
if [ -e "$ALLOWLIST" ] || [ -L "$ALLOWLIST" ]; then
  [ -f "$ALLOWLIST" ] && [ -r "$ALLOWLIST" ] || {
    echo "error: worker environment allowlist '$ALLOWLIST' is not a readable regular file" >&2
    exit 1
  }
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%$'\r'}
    case "$name" in
      ''|'#'*) continue ;;
      *[!A-Za-z0-9_]*|[0-9]* )
        echo "error: worker environment allowlist contains an invalid variable name" >&2
        exit 1
        ;;
    esac
    ALLOWED+=("$name")
    ALLOWED_COUNT=$((ALLOWED_COUNT + 1))
  done < "$ALLOWLIST"
fi

is_allowed_name() {
  local candidate=$1 allowed
  [ "$ALLOWED_COUNT" -gt 0 ] || return 1
  for allowed in "${ALLOWED[@]}"; do
    [ "$candidate" != "$allowed" ] || return 0
  done
  return 1
}

is_secret_name() {
  local upper
  upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$upper" in
    *_API_KEY|*_TOKEN|*_SECRET|*_PASSWORD|*_PASSWD|*KEY) return 0 ;;
    *) return 1 ;;
  esac
}

is_default_worker_name() {
  case "$1" in
    PATH|HOME|SHELL|TERM|LANG|TMPDIR|GOTMPDIR|TRACEPARENT|LC_*|FM_*|HERDR_*|TMUX|TMUX_*|\
    CMUX_*|ZELLIJ*|ORCA_*|CLAUDE*|ANTHROPIC*|CODEX*|OPENAI*|OPENCODE*|PI_*|GROK*|XAI*|\
    KIMI*|MOONSHOT*|MUSE*|CURSOR*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

kept=()
dropped=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if is_allowed_name "$name"; then
    kept+=("$name=${!name}")
  elif is_secret_name "$name"; then
    dropped=$((dropped + 1))
  elif is_default_worker_name "$name"; then
    kept+=("$name=${!name}")
  else
    dropped=$((dropped + 1))
  fi
done < <(compgen -e)

echo "worker environment scrub: dropped $dropped variables" >&2
if [ -n "$SHELL_COMMAND" ]; then
  exec env -i "${kept[@]}" "${SHELL:-/bin/sh}" -c "$SHELL_COMMAND"
fi
exec env -i "${kept[@]}" "$@"
