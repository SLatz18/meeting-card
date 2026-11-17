#!/usr/bin/env bash
# Tests for kit-sync.sh on a scratch copy of the Kit and a scratch upstream repo (no network).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/kit-sync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
fail() { echo "not ok - $1" >&2; exit 1; }

export KIT_DIR="$TMP/kit"
mkdir -p "$KIT_DIR/Sources/A" "$KIT_DIR/Tests/ATests"
echo "// a" > "$KIT_DIR/Sources/A/A.swift"
echo "// t" > "$KIT_DIR/Tests/ATests/T.swift"
echo "// p" > "$KIT_DIR/Package.swift"
echo "readme" > "$KIT_DIR/README.md"

# Scratch upstream with mac/ history.
UP="$TMP/upstream"
git init -q -b master "$UP"
g() { git -C "$UP" -c user.name=t -c user.email=t@example.invalid "$@"; }
mkdir -p "$UP/mac" "$UP/demo"
echo 1 > "$UP/mac/x.swift"; g add -A; g commit -qm "mac: first"
base="$(g rev-parse HEAD)"

"$SCRIPT" record --upstream "$base" >/dev/null
"$SCRIPT" check >/dev/null || fail "check passes right after record"
ok "check passes right after record"

grep -q "^upstream_sha=$base$" "$KIT_DIR/SYNC" || fail "SYNC records the upstream sha"
ok "SYNC records the upstream sha"

echo "readme edit" >> "$KIT_DIR/README.md"
"$SCRIPT" check >/dev/null || fail "README edits are outside the hash"
ok "README edits are outside the hash"

echo "// edited" >> "$KIT_DIR/Sources/A/A.swift"
out="$("$SCRIPT" check 2>&1)" && fail "editing a vendored file fails the check"
grep -q "changed: Sources/A/A.swift" <<<"$out" || fail "failure names the changed file"
grep -q "kit-sync.sh record" <<<"$out" || fail "failure says how to re-record"
ok "editing a vendored file fails, names it, and says how to re-record"

echo "// new" > "$KIT_DIR/Tests/ATests/New.swift"
rm "$KIT_DIR/Package.swift"
out="$("$SCRIPT" check 2>&1)" && fail "added/removed files fail the check"
grep -q "added:   Tests/ATests/New.swift" <<<"$out" || fail "names the added file"
grep -q "removed: Package.swift" <<<"$out" || fail "names the removed file"
ok "added and removed files are named"

echo "// p" > "$KIT_DIR/Package.swift"
"$SCRIPT" record >/dev/null
"$SCRIPT" check >/dev/null || fail "re-record keeps the upstream sha and passes"
grep -q "^upstream_sha=$base$" "$KIT_DIR/SYNC" || fail "re-record keeps the upstream sha"
ok "re-record without --upstream keeps the upstream sha"

"$SCRIPT" record --upstream abc123 >/dev/null 2>&1 && fail "short sha rejected"
ok "short upstream sha is rejected"

export LISTEN_MORE_DIR="$UP" LISTEN_MORE_REF=master
out="$("$SCRIPT" upstream --no-fetch)" || fail "upstream mode passes when in sync"
grep -q "up to date" <<<"$out" || fail "reports up to date"
ok "upstream mode: up to date"

echo 2 > "$UP/mac/x.swift"; g commit -qam "mac: second"
echo d > "$UP/demo/clip.json"; g add -A; g commit -qm "demo only"
echo 3 > "$UP/mac/y.swift"; g add -A; g commit -qm "mac: third"
out="$("$SCRIPT" upstream --no-fetch)" || fail "being behind is a report, not a failure"
grep -q "BEHIND. 2 commit(s) touching mac/" <<<"$out" || fail "counts mac/ commits behind: $out"
grep -q "3 commits in all" <<<"$out" || fail "counts all commits"
grep -q "mac: third" <<<"$out" || fail "lists the commits"
grep -q "mac/y.swift" <<<"$out" || fail "lists the files"
! grep -q "demo/clip.json" <<<"$out" || fail "ignores files outside mac/"
ok "upstream mode: counts and lists mac/ commits behind, ignores other paths"

echo "// drift" >> "$KIT_DIR/Sources/A/A.swift"
"$SCRIPT" upstream --no-fetch >/dev/null 2>&1 && fail "upstream mode also fails on local drift"
ok "upstream mode fails on local drift"

unset LISTEN_MORE_DIR
"$SCRIPT" upstream --no-fetch >/dev/null 2>&1 && fail "upstream mode needs LISTEN_MORE_DIR"
ok "upstream mode is opt-in (needs LISTEN_MORE_DIR)"

# Git work tree (how the real Kit is hashed): untracked files count, ignored build output doesn't.
export KIT_DIR="$TMP/repo/kit"
mkdir -p "$KIT_DIR/Sources/A"
echo "// a" > "$KIT_DIR/Sources/A/A.swift"
echo "// p" > "$KIT_DIR/Package.swift"
echo ".build/" > "$KIT_DIR/.gitignore"
git init -q "$TMP/repo"
git -C "$TMP/repo" add -A
"$SCRIPT" record --upstream "$base" >/dev/null
mkdir -p "$KIT_DIR/.build/x"; echo junk > "$KIT_DIR/.build/x/B.swift"
"$SCRIPT" check >/dev/null || fail "ignored build output is outside the hash"
echo "// new" > "$KIT_DIR/Sources/A/New.swift"
out="$("$SCRIPT" check 2>&1)" && fail "an untracked new file fails the check"
grep -q "added:   Sources/A/New.swift" <<<"$out" || fail "names the untracked file"
ok "git work tree: untracked files count, ignored build output doesn't"

echo "kit-sync tests: $pass passed"
