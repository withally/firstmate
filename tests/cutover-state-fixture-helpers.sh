#!/usr/bin/env bash
# Shared materializer for copied fork version-5 cursor and presentation fixtures.

FM_CUTOVER_FIXTURES="$ROOT/tests/fixtures/fm-cutover-state-migration"

fm_cutover_status_ident() {  # <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$1"
  else
    LC_ALL=C stat -c '%d:%i' "$1"
  fi
}

fm_cutover_status_generation() {  # <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%B' "$1"
  else
    LC_ALL=C stat -c '%W' "$1"
  fi
}

fm_cutover_status_anchor() {  # <file> <offset>
  local file=$1 offset=$2 length=256 start value
  [ "$offset" -ge "$length" ] || length=$offset
  start=$((offset - length))
  value=$(dd if="$file" bs=1 skip="$start" count="$length" 2>/dev/null | LC_ALL=C cksum) \
    || return 1
  value=${value//[[:space:]]/:}
  printf '%s' "$value"
}

fm_cutover_render_fixture() {  # <fixture-name> <state> <task>
  local fixture=$1 state=$2 task=$3 status offset ident generation anchor
  mkdir -p "$state"
  status="$state/$task.status"
  cp "$FM_CUTOVER_FIXTURES/$fixture/status.log" "$status"
  offset=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  ident=$(fm_cutover_status_ident "$status")
  generation=$(fm_cutover_status_generation "$status")
  anchor=$(fm_cutover_status_anchor "$status" "$offset")
  sed -e "s/{{OFFSET}}/$offset/g" \
      -e "s/{{IDENT}}/$ident/g" \
      -e "s/{{GENERATION}}/$generation/g" \
      -e "s/{{ANCHOR}}/$anchor/g" \
      "$FM_CUTOVER_FIXTURES/$fixture/open-decisions.cursor.in" > "$state/.$task.open-decisions-cursor"
  sed -e "s/{{OFFSET}}/$offset/g" \
      -e "s/{{IDENT}}/$ident/g" \
      "$FM_CUTOVER_FIXTURES/$fixture/presentation.cursor.in" > "$state/.status-presentation-cursor"
}
