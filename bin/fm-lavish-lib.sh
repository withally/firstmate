#!/usr/bin/env bash
# Shared path boundary for every Firstmate-owned Lavish review operation.

fm_lavish_refuse_artifact() {  # <artifact> <reason>
  printf 'REFUSED: Lavish review artifact is not durable: %s\n' "$1" >&2
  printf 'Reason: %s\n' "$2" >&2
  printf 'Use a stable file under %s/data/<review-id>/.lavish/<name>.html and keep updating that same file.\n' "$FM_HOME" >&2
  return 1
}

fm_lavish_realpath() {  # <path>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

fm_lavish_artifact_id() {  # <canonical-artifact-path>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  fi
}

fm_lavish_require_durable_artifact() {  # <artifact>: print canonical path
  local artifact=${1-} real home_real
  [ -n "$artifact" ] || {
    printf 'error: a Lavish artifact path is required\n' >&2
    return 1
  }
  case "$artifact" in
    *$'\n'*)
      fm_lavish_refuse_artifact "$artifact" "artifact paths cannot contain newlines"
      return 1
      ;;
  esac
  real=$(fm_lavish_realpath "$artifact") || {
    printf 'error: cannot resolve the Lavish artifact path: %s\n' "$artifact" >&2
    return 1
  }
  [ -f "$real" ] || {
    printf 'error: Lavish artifact does not exist: %s\n' "$artifact" >&2
    return 1
  }
  home_real=$(fm_lavish_realpath "$FM_HOME") || {
    printf 'error: cannot resolve FM_HOME: %s\n' "$FM_HOME" >&2
    return 1
  }
  case "$real" in
    /tmp/*|/private/tmp/*|/var/tmp/*|/var/folders/*|*/claude-501/*)
      fm_lavish_refuse_artifact "$real" "temporary and claude-501 scratch paths can be discarded"
      return 1
      ;;
  esac
  case "$real" in
    "$home_real"/data/*/.lavish/*.html) ;;
    *)
      fm_lavish_refuse_artifact "$real" "the artifact is outside this home's durable Lavish review tree"
      return 1
      ;;
  esac
  printf '%s\n' "$real"
}
