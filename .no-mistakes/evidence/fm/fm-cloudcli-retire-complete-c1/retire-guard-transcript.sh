#!/usr/bin/env bash
# Manual verification harness: drives the REAL remote-side CLI
# bin/fm-remote-secondmate-control.sh retire <id> against fixture homes.
# This is the exact command the primary's fm-teardown.sh runs over SSH.
set -u
ROOT=${1:?repo root required}
TMP=$(mktemp -d /tmp/fm-retire-evidence.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
CTL="$ROOT/bin/fm-remote-secondmate-control.sh"

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }

seed_residue() { # <home>
  local home=$1 bytes hash
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"
  printf 'codex\n' > "$home/config/crew-harness"
  bytes=$(LC_ALL=C wc -c < "$home/config/crew-harness" | tr -d ' ')
  hash=$(sha256_file "$home/config/crew-harness")
  printf '3\n%s\n%s\nput\n' "$bytes" "$hash" > "$home/config/.fm-inherit-crew-harness.generation"
  printf 'shared preferences\n' > "$home/data/captain-shared.md"
  bytes=$(LC_ALL=C wc -c < "$home/data/captain-shared.md" | tr -d ' ')
  hash=$(sha256_file "$home/data/captain-shared.md")
  printf '4\n%s\n%s\nput\n' "$bytes" "$hash" > "$home/data/.fm-inherit-captain-shared.md.generation"
  printf 'diverged\n' > "$home/data/captain-shared.md.remote-quarantine-20260101T000000Z-4242"
  mkdir "$home/config/.fm-inherit-crew-harness.lock.owner.aB3d9Z"
  printf '4242\n' > "$home/config/.fm-inherit-crew-harness.lock.owner.aB3d9Z/pid"
  ln -s "$home/config/.fm-inherit-crew-harness.lock.owner.aB3d9Z" "$home/config/.fm-inherit-crew-harness.lock"
  printf 'partial payload\n' > "$home/data/.inherit.Qz71xW"
}

run_case() { # <label> <home>
  local label=$1 home=$2 out rc before after
  before=$(cd "$(dirname "$home")" 2>/dev/null && find "$(basename "$home")" 2>/dev/null | sort || echo '<absent>')
  out=$(FM_HOME="$home" "$CTL" retire ios 2>&1); rc=$?
  after=$(cd "$(dirname "$home")" 2>/dev/null && find "$(basename "$home")" 2>/dev/null | sort || echo '<absent>')
  printf '\n=== %s ===\n' "$label"
  printf '$ FM_HOME=%s fm-remote-secondmate-control.sh retire ios\n' "${home##*/}"
  printf '%s\n' "$out" | sed 's/^/  /'
  printf 'exit: %s\n' "$rc"
  if [ "$before" = "$after" ]; then
    printf 'remote home on disk: UNCHANGED (nothing deleted)\n'
  else
    printf 'remote home on disk: CHANGED\n  --- before\n%s\n  --- after\n%s\n' "$before" "$after"
  fi
}

# 1. already-retired: home recreated by inheritance propagation only
H="$TMP/retired-residue"; seed_residue "$H"
run_case "already-retired remote home (inheritance residue only)" "$H"

# 2. absent home
run_case "absent remote home" "$TMP/never-existed"

# 3. committed 'put' generation whose material was never published
H="$TMP/retired-unpublished"; seed_residue "$H"; rm -f "$H/config/crew-harness"
run_case "committed put generation, material never published" "$H"

# 4. live seeded home -> must NOT short-circuit as already-retired
H="$TMP/live-seeded"; seed_residue "$H"; printf 'ios\n' > "$H/.fm-secondmate-home"
run_case "live seeded secondmate home" "$H"

# 5. unrelated name beside residue -> unsafe, refuse without deleting
H="$TMP/unsafe-extra"; seed_residue "$H"; printf 'stale\n' > "$H/config/crew-harness.bak"
run_case "residue plus a name outside the inheritance family" "$H"

# 6. tampered material vs its hash commitment
H="$TMP/tampered"; seed_residue "$H"; printf 'tampered\n' > "$H/config/crew-harness"
run_case "inherited material diverging from its generation hash" "$H"

# 7. operational directory still holding content
H="$TMP/state-content"; seed_residue "$H"; printf 'worker state\n' > "$H/state/worker.meta"
run_case "retired home whose state/ still holds content" "$H"

# 8. wrong path: an ordinary project directory
H="$TMP/wrong-path"; mkdir -p "$H"; printf '# project\n' > "$H/README.md"; mkdir -p "$H/src"
run_case "wrong path (ordinary project directory)" "$H"
