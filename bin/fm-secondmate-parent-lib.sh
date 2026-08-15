#!/usr/bin/env bash
# shellcheck disable=SC2034 # Parsed fields are returned as globals.
# Parse the durable parent route stored in a seeded secondmate home.

fm_secondmate_parent_record_parse() { # <record>
  local file=$1 line schema='' route='' parent_home='' parent_host=''
  local schemas=0 routes=0 parent_homes=0 parent_hosts=0
  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*) schemas=$((schemas + 1)); schema=${line#schema=} ;;
      route=*) routes=$((routes + 1)); route=${line#route=} ;;
      parent_home=*) parent_homes=$((parent_homes + 1)); parent_home=${line#parent_home=} ;;
      parent_host=*) parent_hosts=$((parent_hosts + 1)); parent_host=${line#parent_host=} ;;
    esac
  done < "$file"

  [ "$schemas" -eq 1 ] && [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  [ "$routes" -eq 1 ] || return 1
  case "$route" in
    local)
      [ "$parent_homes" -eq 1 ] && [ "$parent_hosts" -eq 0 ] || return 1
      case "$parent_home" in /|'') return 1 ;; /*) ;; *) return 1 ;; esac
      FM_SECONDMATE_PARENT_HOME=$parent_home
      ;;
    remote)
      [ "$parent_homes" -eq 0 ] || return 1
      [ "$parent_hosts" -le 1 ] || return 1
      ;;
    *) return 1 ;;
  esac
  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
}
