#!/usr/bin/env bash
# E2E repro of the 2026-08-24 Mac-freeze defect.
#
# Precondition: a lock whose parent directory does not exist (the state dir was
# never created / was removed under a running watcher). Before the fix,
# fm_lock_try_acquire could not create the primary lock, so it recursed into
# "<lock>.steal", then "<lock>.steal.steal", ... without bound, forking helper
# processes at every level. That is the runaway that froze the Mac.
#
# usage: repro-recursion.sh <path-to-fm-wake-lib.sh>
set -u
LIB=$1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-freeze-repro.XXXXXX")
SHIM="$WORK/shim"; mkdir -p "$SHIM"
COUNT="$WORK/launches"; : > "$COUNT"
# Count every external process the lock path launches, so a runaway is visible
# as a process-launch budget blowout and not only as wall-clock hang.
for tool in mktemp basename dirname cat date mkdir rmdir ln rm mv stat; do
  real=$(command -v "$tool")
  cat > "$SHIM/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$COUNT"
exec "$real" "\$@"
EOF
  chmod +x "$SHIM/$tool"
done

LOCK="$WORK/no-such-parent/.wake-queue.lock"
ERR="$WORK/child.err"

echo "lock path        : \$WORK/no-such-parent/.wake-queue.lock"
echo "parent dir exists: $([ -d "$(dirname "$LOCK")" ] && echo yes || echo no)"

PATH="$SHIM:$PATH" perl -e '
  $pid = fork();
  if ($pid == 0) { exec(@ARGV) or exit 127 }
  $SIG{ALRM} = sub { kill "KILL", $pid; waitpid($pid,0);
                     print "outcome          : HUNG - killed after 20s (never returned)\n"; exit 99 };
  alarm 20;
  waitpid($pid, 0);
  printf("outcome          : returned status %d\n", $? >> 8);
  exit $? >> 8;
' bash -c '
  . "$1"
  rc=0
  fm_lock_try_acquire "$2" || rc=$?
  exit "$rc"
' _ "$LIB" "$LOCK" 2> "$ERR"
rc=$?

echo "process launches : $(wc -l < "$COUNT" | tr -d ' ')"
deep=$(sed "s|$WORK||g" "$COUNT" "$ERR" 2>/dev/null | awk '{n=gsub(/\.steal/,"x"); if(n>m){m=n}} END{print m+0}')
echo "deepest .steal chain reached: $deep"
if [ "$deep" -gt 0 ]; then
  echo "sample runaway path (truncated to 160 chars):"
  sed "s|$WORK||g" "$ERR" | grep -o '[^ ]*\.steal\(\.steal\)*' | sort -u | tail -1 | cut -c1-160
  echo "  ...(continues)"
fi
rm -rf "$WORK"
exit $rc
