#!/bin/zsh
# Render screenshots from BUILT copies (Release, build/dd) for the CI snapshot job. Never installs.
#   scripts/snapshots.sh cards <base-swift-dir> <head-swift-dir> <out-dir>
#       each reminder card (light + dark) from both builds back to back, into <out>/base and
#       <out>/head; a pair is re-rendered once if they differ (the clock minute can roll over
#       between the two renders and the card shows absolute times)
#   scripts/snapshots.sh coach <out-dir>
#       coach chip states, glow, Settings, onboarding, status menu and the design packet
#       (packet-<surface>-<appearance>.png) from this checkout's build
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Start 10 min out: the "in 10 min" title is stable across a pair.
export SHIFT=600

shot() {  # <swift-dir> <fixture> <appearance> <png> [env...]
  local dir="$1" f="$2" a="$3" png="$4"; shift 4
  (cd "$dir" && env "$@" scripts/show-fixture.sh "$f" "$a" 2 --snapshot "$png" >/dev/null 2>&1) || true
}

case "${1:-}" in
  cards)
    BASE="$(cd "$2" && pwd)"; HEAD="$(cd "$3" && pwd)"; OUT="$(mkdir -p "$4" && cd "$4" && pwd)"
    mkdir -p "$OUT/base" "$OUT/head"
    cases=()
    for f in meet zoom multilink nolink teams; do for a in light dark; do cases+=("${f}:${a}:card-${f}-${a}:"); done; done
    for a in light dark; do cases+=("meet:${a}:card-meet-nextup-${a}:NEXT=nextup"); done
    for c in "${cases[@]}"; do
      IFS=: read -r f a name extra <<<"$c"
      envs=(); [[ -n "$extra" ]] && envs=("$extra")
      for attempt in 1 2; do
        shot "$BASE" "$f" "$a" "$OUT/base/$name.png" "${envs[@]}"
        shot "$HEAD" "$f" "$a" "$OUT/head/$name.png" "${envs[@]}"
        cmp -s "$OUT/base/$name.png" "$OUT/head/$name.png" && break
      done
    done
    ls "$OUT/base" "$OUT/head"
    ;;
  coach)
    OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
    for chip in on listening paused; do
      for a in light dark; do
        shot "$HERE" meet "$a" "$OUT/coach-chip-$chip-$a.png" MEETING_CARD_COACH_CHIP="$chip"
      done
    done
    # Glow, Settings, onboarding, the status menu and the design packet (packet-*.png: the card
    # beside each coach surface). The fixture log's coach-shot lines (names and sizes only) are kept.
    LOG="$HOME/Library/Logs/MeetingCardSwift-fixture.log"
    for a in light dark; do
      (cd "$HERE" && MEETING_CARD_COACH_CHIP=listening MEETING_CARD_COACH_SHOTS="$OUT" \
        scripts/show-fixture.sh meet "$a" 20 >/dev/null 2>&1) || true
      grep -hE "coach (shot|packet|menu)" "$LOG" >> "$OUT/coach-shots.log" 2>/dev/null || true
    done
    ls "$OUT"
    ;;
  *) echo "usage: $0 cards <base-swift> <head-swift> <out> | coach <out>" >&2; exit 2 ;;
esac
