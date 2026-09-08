# AFK Herdr + Claude live-guard test evidence

Date: 2026-09-08 Asia/Hong_Kong.

Target: `7397e53296fdecf5d4d0c447fcf793ad0a748a8e`.

The provided baseline `bin/fm-test-run.sh --changed --exclude-family real-herdr-gated` had already completed successfully before this test phase.

## Focused portable behavior

Commands:

```text
bash tests/fm-composer-lib.test.sh
bash tests/fm-turnend-guard.test.sh
```

Relevant observable results:

```text
ok - fm_claude_current_footer_busy: the footer belongs to the selected composer boundary
ok - fm_claude_current_footer_busy: Claude 2.1.263 titled-rule composers and permission-mode footers stay readable
ok - fm-turnend-guard: away mode attempts relaunch and blocks if dead-daemon recovery fails
ok - fm-turnend-guard: dead away-daemon ownership is checked before a live watcher can allow
ok - fm-turnend-guard: a turn boundary relaunches a dead away daemon through fm-afk-launch.sh
ok - fm-turnend-guard: dead-daemon relaunch requires a post-launch heartbeat
```

## Real Herdr + Claude 2.1.263, auto mode

Command:

```text
HERDR_LAB_HELPER=/Users/ivan/.no-mistakes/worktrees/37852af5566c/01M1Z6QTKQRP9XRY4HBQY9P42V/bin/fm-herdr-lab.sh FM_AFK_HERDR_CLAUDE_LIVE=1 FM_AFK_HERDR_CLAUDE_PERMISSION_MODE=auto bin/fm-test-run.sh tests/fm-afk-herdr-claude-busy-guard-live-e2e.test.sh
```

The named non-default lab run showed an idle native state with an empty rendered composer, then a genuine foreground spinner and preserved human text:

```text
verdict: idle-post-afk agent_status=idle composer=empty pane_is_busy_rc=1 broad_match_rc=1 scoped_match_rc=1 subcause=idle native-state=idle matched-row=none
⏵⏵ auto mode on · 1 shell · ← 1 agent · ↓ to manage
ok - real Herdr 0.8.2 + Claude 2.1.263 (Claude Code) (auto mode): native idle with rendered-idle empty composer submits once
verdict: active-foreground native-state=working subcause=rendered-busy matched-row=✶ Caramelizing… (15s · ↓ 127 tokens)
ok - real Herdr 0.8.2 + Claude 2.1.263 (Claude Code) (auto mode): rendered-busy and pending-composer deferrals preserve human text
evidence: permission-mode=auto native=idle rendered=idle composer=empty stable-footer-composer=3 delivery-ms=4125 delivery-bound-ms=6000 delivered_once=1 rendered-busy=1 native-state=working=1 composer=pending=1
FM_TEST_END 2026-09-08T02:32:18Z tests/fm-afk-herdr-claude-busy-guard-live-e2e.test.sh exit=0 duration_ms=71096 gate_skip=false
```

## Real Herdr + Claude 2.1.263, bypass-permissions mode

Command:

```text
HERDR_LAB_HELPER=/Users/ivan/.no-mistakes/worktrees/37852af5566c/01M1Z6QTKQRP9XRY4HBQY9P42V/bin/fm-herdr-lab.sh FM_AFK_HERDR_CLAUDE_LIVE=1 FM_AFK_HERDR_CLAUDE_PERMISSION_MODE=bypassPermissions bin/fm-test-run.sh tests/fm-afk-herdr-claude-busy-guard-live-e2e.test.sh
```

The first attempt was a non-reproducible live harness failure: Claude rendered the bypass footer and answered `/afk` with the test ACK, but did not enter the afk skill lifecycle, so no daemon record appeared.

The identical rerun passed the full end-to-end contract:

```text
verdict: idle-post-afk agent_status=idle composer=empty pane_is_busy_rc=1 broad_match_rc=1 scoped_match_rc=1 subcause=idle native-state=idle matched-row=none
⏵⏵ bypass permissions on · 1 shell · ← 1 agent · ↓ to manage
ok - real Herdr 0.8.2 + Claude 2.1.263 (Claude Code) (bypass permissions): native idle with rendered-idle empty composer submits once
verdict: active-foreground native-state=working subcause=rendered-busy matched-row=✻ Actioning… (12s · ↓ 159 tokens)
ok - real Herdr 0.8.2 + Claude 2.1.263 (Claude Code) (bypass permissions): rendered-busy and pending-composer deferrals preserve human text
evidence: permission-mode=bypassPermissions native=idle rendered=idle composer=empty stable-footer-composer=3 delivery-ms=3979 delivery-bound-ms=6000 delivered_once=1 rendered-busy=1 native-state=working=1 composer=pending=1
FM_TEST_END 2026-09-08T02:37:13Z tests/fm-afk-herdr-claude-busy-guard-live-e2e.test.sh exit=0 duration_ms=90473 gate_skip=false
```

Both successful live runs used generated `fm-lab-*` sessions and the runner reported `gate_skip=false`.
