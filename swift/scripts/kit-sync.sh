#!/usr/bin/env bash
# Sync point for the vendored ListenMoreKit (swift/Packages/ListenMoreKit/SYNC).
#
#   scripts/kit-sync.sh check
#       CI and local. Recomputes the hash of the vendored Kit (Package.swift, Sources/, Tests/) and
#       compares it with SYNC. Fails, listing added/removed/changed files, when the Kit was edited
#       without re-recording the sync point. Needs nothing but the checkout.
#   scripts/kit-sync.sh record [--upstream <40-hex sha>]
#       After porting upstream changes (or a deliberate local edit): rewrite SYNC with the current
#       file hashes, and optionally a new upstream commit.
#   LISTEN_MORE_DIR=<local clone> scripts/kit-sync.sh upstream [--no-fetch]
#       Opt-in, local only (the upstream repo is private; CI never runs this). Runs `check`, fetches
#       the clone, then prints how far the recorded upstream commit is behind
#       ${LISTEN_MORE_REF:-origin/master} for mac/, with the commits and files to port.
#
# KIT_DIR overrides the Kit location (tests).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
KIT="${KIT_DIR:-$HERE/Packages/ListenMoreKit}"
SYNC="$KIT/SYNC"
UPSTREAM_PATH="mac/"

die() { echo "kit-sync: $*" >&2; exit 2; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# Vendored files, relative to the Kit, sorted bytewise. Tracked plus untracked-but-not-ignored files
# when the Kit is in a git work tree, so a new file counts before it is committed.
kit_files() {
  (
    cd "$KIT"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git ls-files -co --exclude-standard -- Package.swift Sources Tests
    else
      find Package.swift Sources Tests -type f ! -path '*/.build/*' ! -name '.*' 2>/dev/null || true
    fi
  ) | LC_ALL=C sort
}

manifest() {  # "<sha256> <path>" per file
  local f
  kit_files | while IFS= read -r f; do
    [[ -f "$KIT/$f" ]] || continue
    printf '%s %s\n' "$(sha256 "$KIT/$f" | cut -d' ' -f1)" "$f"
  done
}

tree_hash() { sha256 | cut -d' ' -f1; }

recorded() { sed -n "s/^$1=//p" "$SYNC" | head -1; }

recorded_manifest() { sed -n 's/^file //p' "$SYNC"; }

cmd_check() {
  [[ -f "$SYNC" ]] || die "no $SYNC; run: scripts/kit-sync.sh record --upstream <sha>"
  local want have m
  want="$(recorded tree_sha256)"
  m="$(manifest)"
  have="$(printf '%s\n' "$m" | tree_hash)"
  if [[ "$want" == "$have" ]]; then
    echo "kit-sync: OK. Vendored Kit matches SYNC (upstream $(recorded upstream_sha | cut -c1-12), $(printf '%s\n' "$m" | wc -l | tr -d ' ') files)."
    return 0
  fi
  echo "kit-sync: FAIL. The vendored Kit changed since the sync point was recorded." >&2
  echo "  recorded tree_sha256 $want" >&2
  echo "  current  tree_sha256 $have" >&2
  local old new
  old="$(recorded_manifest)"
  new="$m"
  join -j 2 -v 2 <(printf '%s\n' "$old" | sort -k2) <(printf '%s\n' "$new" | sort -k2) | awk '{ print "  added:   " $1 }' >&2 || true
  join -j 2 -v 1 <(printf '%s\n' "$old" | sort -k2) <(printf '%s\n' "$new" | sort -k2) | awk '{ print "  removed: " $1 }' >&2 || true
  join -j 2 <(printf '%s\n' "$old" | sort -k2) <(printf '%s\n' "$new" | sort -k2) | awk '$2 != $3 { print "  changed: " $1 }' >&2 || true
  echo "  If this edit is intended (a port from upstream or a MeetingCard adaptation), re-record:" >&2
  echo "    scripts/kit-sync.sh record                      # local edit, same upstream commit" >&2
  echo "    scripts/kit-sync.sh record --upstream <sha>     # after porting upstream up to <sha>" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=swift/Packages/ListenMoreKit/SYNC::Vendored ListenMoreKit changed without updating the sync point (run swift/scripts/kit-sync.sh record)"
  fi
  return 1
}

cmd_record() {
  local up=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upstream) up="${2:-}"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  if [[ -z "$up" ]]; then
    [[ -f "$SYNC" ]] || die "first record needs --upstream <sha>"
    up="$(recorded upstream_sha)"
  fi
  [[ "$up" =~ ^[0-9a-f]{40}$ ]] || die "upstream sha must be 40 lowercase hex characters"
  local m
  m="$(manifest)"
  {
    echo "# ListenMoreKit sync point. Written by swift/scripts/kit-sync.sh record; do not edit by hand."
    echo "# upstream_sha: the listen-more commit whose ${UPSTREAM_PATH} was last ported here."
    echo "# tree_sha256: sha256 of the file lines below (sha256 and path of each vendored file)."
    echo "upstream_sha=$up"
    echo "upstream_path=$UPSTREAM_PATH"
    echo "tree_sha256=$(printf '%s\n' "$m" | tree_hash)"
    printf '%s\n' "$m" | sed 's/^/file /'
  } > "$SYNC"
  echo "kit-sync: recorded upstream ${up:0:12}, $(printf '%s\n' "$m" | wc -l | tr -d ' ') files."
}

cmd_upstream() {
  local fetch=1
  [[ "${1:-}" == "--no-fetch" ]] && fetch=0
  [[ -n "${LISTEN_MORE_DIR:-}" ]] || die "set LISTEN_MORE_DIR to a local clone of listen-more (opt-in; CI never runs this)"
  git -C "$LISTEN_MORE_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "LISTEN_MORE_DIR is not a git clone"
  local status=0
  cmd_check || status=1
  local ref="${LISTEN_MORE_REF:-origin/master}" sync
  sync="$(recorded upstream_sha)"
  if [[ $fetch == 1 ]] && ! git -C "$LISTEN_MORE_DIR" fetch -q origin 2>/dev/null; then
    echo "kit-sync: WARN. Upstream unreachable; comparing against the clone's last fetch." >&2
  fi
  git -C "$LISTEN_MORE_DIR" rev-parse -q --verify "$ref^{commit}" >/dev/null || die "no $ref in the clone"
  if ! git -C "$LISTEN_MORE_DIR" cat-file -e "$sync^{commit}" 2>/dev/null; then
    echo "kit-sync: FAIL. Recorded upstream ${sync:0:12} is not in the clone (rewritten history or wrong repo)." >&2
    return 1
  fi
  if ! git -C "$LISTEN_MORE_DIR" merge-base --is-ancestor "$sync" "$ref"; then
    echo "kit-sync: WARN. Recorded upstream ${sync:0:12} is not an ancestor of $ref." >&2
  fi
  local behind total
  behind="$(git -C "$LISTEN_MORE_DIR" rev-list --count "$sync..$ref" -- "$UPSTREAM_PATH")"
  total="$(git -C "$LISTEN_MORE_DIR" rev-list --count "$sync..$ref")"
  if [[ "$behind" == 0 ]]; then
    echo "kit-sync: up to date. No ${UPSTREAM_PATH} changes in $ref since ${sync:0:12} ($total other commits)."
  else
    echo "kit-sync: BEHIND. $behind commit(s) touching ${UPSTREAM_PATH} in $ref since ${sync:0:12} ($total commits in all):"
    git -C "$LISTEN_MORE_DIR" log --format='  %h %s' "$sync..$ref" -- "$UPSTREAM_PATH"
    echo "  files to review:"
    git -C "$LISTEN_MORE_DIR" diff --stat=100 "$sync" "$ref" -- "$UPSTREAM_PATH" | sed 's/^/  /'
    echo "  Port code and generic defaults only, then: scripts/kit-sync.sh record --upstream $(git -C "$LISTEN_MORE_DIR" rev-parse "$ref")"
  fi
  return $status
}

case "${1:-}" in
  check) cmd_check ;;
  record) shift; cmd_record "$@" ;;
  upstream) shift; cmd_upstream "$@" ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
