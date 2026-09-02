# Away-mode catch-all behavioral evidence

Target commit: `33a422b1de75fc5ba427d0410ce329deb4255879`.

## Baseline reproduction

The same presented-before-away scenario executed against the base daemon from `19ff5e1faf7846388e776759c5ceb50c45eb4c05` produced:

```text
BASE_EXPECTED_FAILURE: pre-fix catch-all escalated a status already covered by the presentation cursor
BASE_DELIVERY: {"nonce":"","kind":"escalation","source_key":"","text":"pilo-continuity-s1.status: done: prototype server stopped after review (catch-all scan)","state":"buffered"}
```

## Target behavioral run

Command: `bin/fm-test-run.sh tests/fm-supervise-daemon-catchall.test.sh`

```text
ok - catch-all ignores a status line presented before away-mode entry
ok - legacy ident-prefixed markers settle and migrate
ok - catch-all escalates an identical status append after the seen marker
ok - catch-all does not reuse a seen marker across task-file incarnations
ok - catch-all preserves a racing identical append after marker capture
ok - catch-all keeps status appended after away-mode entry eligible
FM_TEST_END ... exit=0 ...
```

The focused run demonstrates that settled history is not re-escalated, while later identical appends, replacement file incarnations, and post-away status lines remain eligible.
