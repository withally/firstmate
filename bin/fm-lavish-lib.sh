#!/usr/bin/env bash

fm_lavish_state_dir() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$1" in
    /*/state.json) printf '%s\n' "$(dirname "$1")" ;;
    *) return 1 ;;
  esac
}
