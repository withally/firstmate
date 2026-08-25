#!/usr/bin/env bash
set -u
TREE=$1; LABEL=$2
T=$(mktemp -d /tmp/fm-hang.XXXXXX); mkdir -p "$T/home/state" "$T/home/config" "$T/fakebin"
cat > "$T/fakebin/git" <<'SH'
#!/usr/bin/env bash
trap '' TERM
sleep 600
SH
chmod +x "$T/fakebin/git"
start=$(date +%s)
out=$(PATH="$T/fakebin:$PATH" FM_HOME="$T/home" FM_STATE_OVERRIDE="$T/home/state" \
  FM_CONFIG_OVERRIDE="$T/home/config" FM_SESSION_START_TIMEOUT=3 FM_STARTUP_NETWORK_TIMEOUT=2 \
  timeout 25 "$TREE/bin/fm-session-start.sh" 2>&1) ; rc=$?
end=$(date +%s)
printf '%s\n' "=== $LABEL (session-start runtime bound: 3s) ==="
printf 'exit=%s wall=%ss\n' "$rc" "$((end - start))"
printf '%s\n' "$out"
printf '%s\n\n' "---"
rm -rf "$T"
