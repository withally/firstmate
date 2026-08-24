# Remote secondmate retirement guard — before vs after

Command exercised (the exact remote-side CLI the primary's `fm-teardown.sh` runs over SSH):

```
FM_HOME=<remote-home> bin/fm-remote-secondmate-control.sh retire ios
```

## BASE c735ec1 (before fix)

```

=== already-retired remote home (inheritance residue only) ===
$ FM_HOME=retired-residue fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== absent remote home ===
$ FM_HOME=never-existed fm-remote-secondmate-control.sh retire ios
  already-retired: ios
exit: 0
remote home on disk: UNCHANGED (nothing deleted)

=== committed put generation, material never published ===
$ FM_HOME=retired-unpublished fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== live seeded secondmate home ===
$ FM_HOME=live-seeded fm-remote-secondmate-control.sh retire ios
  error: remote home is not a Firstmate checkout
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== residue plus a name outside the inheritance family ===
$ FM_HOME=unsafe-extra fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== inherited material diverging from its generation hash ===
$ FM_HOME=tampered fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== retired home whose state/ still holds content ===
$ FM_HOME=state-content fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== wrong path (ordinary project directory) ===
$ FM_HOME=wrong-path fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)
```

## HEAD 051dcef (after fix)

```

=== already-retired remote home (inheritance residue only) ===
$ FM_HOME=retired-residue fm-remote-secondmate-control.sh retire ios
  already-retired: ios
exit: 0
remote home on disk: UNCHANGED (nothing deleted)

=== absent remote home ===
$ FM_HOME=never-existed fm-remote-secondmate-control.sh retire ios
  already-retired: ios
exit: 0
remote home on disk: UNCHANGED (nothing deleted)

=== committed put generation, material never published ===
$ FM_HOME=retired-unpublished fm-remote-secondmate-control.sh retire ios
  already-retired: ios
exit: 0
remote home on disk: UNCHANGED (nothing deleted)

=== live seeded secondmate home ===
$ FM_HOME=live-seeded fm-remote-secondmate-control.sh retire ios
  error: remote home is not a Firstmate checkout
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== residue plus a name outside the inheritance family ===
$ FM_HOME=unsafe-extra fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== inherited material diverging from its generation hash ===
$ FM_HOME=tampered fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== retired home whose state/ still holds content ===
$ FM_HOME=state-content fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)

=== wrong path (ordinary project directory) ===
$ FM_HOME=wrong-path fm-remote-secondmate-control.sh retire ios
  error: remote home is not a seeded secondmate home
exit: 1
remote home on disk: UNCHANGED (nothing deleted)
```
