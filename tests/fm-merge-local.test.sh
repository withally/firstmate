#!/usr/bin/env bash
# Behavioral coverage for merge-authority enforcement on local-only landings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
home="$TMP_ROOT/home"
parent="$TMP_ROOT/parent"
project="$TMP_ROOT/project"
id=local-authority-x1
mkdir -p "$home/state" "$parent/data" "$parent/state"
touch "$home/state/.last-watcher-beat"

git init -q -b main "$project"
printf 'base\n' > "$project/value"
git -C "$project" add value
git -C "$project" commit -qm base
git -C "$project" checkout -qb "fm/$id"
printf 'landed\n' > "$project/value"
git -C "$project" commit -qam feature
feature_head=$(git -C "$project" rev-parse HEAD)
git -C "$project" checkout -q main
base_head=$(git -C "$project" rev-parse HEAD)

printf '%s\n' mate-x > "$home/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
  > "$home/.fm-secondmate-parent"
printf -- '- mate-x - test route (home: %s; scope: test; projects: alpha; added 2026-08-30)\n' \
  "$home" > "$parent/data/secondmates.md"
cat > "$home/state/$id.meta" <<EOF
project=$project
kind=ship
mode=local-only
yolo=off
merge_authority=firstmate
spawn_gen=spawn-a
EOF

printf 'needs-decision [key=before-landing-%s-spawn-a]: approve local landing\n' "$id" \
  > "$parent/state/mate-x.status"
if FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" "$id" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail "firstmate-authority local landing succeeded without resolved parent approval"
fi
[ "$(git -C "$project" rev-parse main)" = "$base_head" ] \
  || fail "refused local landing moved main"
assert_grep 'parent-firstmate approval is not resolved' "$TMP_ROOT/err" \
  "local refusal did not name the missing parent resolution"

awk '$0 !~ /^merge_authority=/' "$home/state/$id.meta" > "$TMP_ROOT/invalid-meta"
printf 'merge_authority=self\n' >> "$TMP_ROOT/invalid-meta"
mv "$TMP_ROOT/invalid-meta" "$home/state/$id.meta"
if FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" "$id" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
  fail "self authority with yolo=off bypassed the local merge tuple gate"
fi
assert_grep 'invalid merge_authority record' "$TMP_ROOT/err" \
  "local merge tuple refusal did not identify the invalid durable record"
awk '$0 !~ /^merge_authority=/' "$home/state/$id.meta" > "$TMP_ROOT/valid-meta"
printf 'merge_authority=firstmate\n' >> "$TMP_ROOT/valid-meta"
mv "$TMP_ROOT/valid-meta" "$home/state/$id.meta"

printf 'resolved [key=before-landing-%s-spawn-a]: approved by parent firstmate\n' "$id" \
  >> "$parent/state/mate-x.status"
FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" "$id" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" \
  || fail "resolved parent approval did not permit the local landing"
[ "$(git -C "$project" rev-parse main)" = "$feature_head" ] \
  || fail "approved local landing did not fast-forward main"
assert_grep "merged fm/$id into local main" "$TMP_ROOT/out" \
  "approved local landing did not report its result"

pass "fm-merge-local accepts a registered parent-firstmate resolution and refuses its absence"
