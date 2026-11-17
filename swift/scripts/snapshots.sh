#!/bin/zsh
# Render screenshots from BUILT copies (Release, build/dd) for the CI snapshot job. Never installs.
#   scripts/snapshots.sh cards <base-swift-dir> <head-swift-dir> <out-dir>
#       each reminder card (light + dark) from both builds back to back, into <out>/base and
#       <out>/head; a pair is re-rendered once if they differ (the clock minute can roll over
#       between the two renders and the card shows absolute times)
#   scripts/snapshots.sh coach <out-dir>
#       coach chip states (incl. the multi-link card, full and collapsed), glow, Settings (incl. the
#       TypeSafe cue judge, and its feedback row), onboarding, status menu, the feedback notice, caption
#       strip, saving indicator, transcript notice, transcript settings and the design packet
#       (packet-<surface>-<appearance>.png, listed in packet-list.txt), and the coach card and pill
#       states with the morph and collapse end states (coach-<state>-<appearance>.png) from this
#       checkout's build; fails if a Use Zoom/Meet controls packet or a coach card state is missing
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
    for chip in on listening paused muted; do
      for a in light dark; do
        shot "$HERE" meet "$a" "$OUT/coach-chip-$chip-$a.png" MEETING_CARD_COACH_CHIP="$chip"
      done
    done
    # The wide multi-link "Open in Calendar" button: the real label (full chip, 8 pt clear of
    # Ignore and the button) and a long label (the collapse rule: icon-only, button untouched).
    for a in light dark; do
      shot "$HERE" multilink "$a" "$OUT/coach-chip-multilink-$a.png" MEETING_CARD_COACH_CHIP=listening
      shot "$HERE" multilink "$a" "$OUT/coach-chip-collapsed-multilink-$a.png" MEETING_CARD_COACH_CHIP=listening \
        MEETING_CARD_COACH_CHIP_LABEL="Listening to this call"
    done
    # Glow, Settings, onboarding, the status menu, the feedback notice, the caption and transcript
    # surfaces and the design packet (packet-*.png: the card beside each coach surface). The fixture
    # log's coach-shot lines (names and sizes only) are kept.
    LOG="$HOME/Library/Logs/MeetingCardSwift-fixture.log"
    for a in light dark; do
      (cd "$HERE" && MEETING_CARD_COACH_CHIP=listening MEETING_CARD_COACH_SHOTS="$OUT" \
        scripts/show-fixture.sh meet "$a" 30 >/dev/null 2>&1) || true
      grep -hE "coach (shot|packet|menu|notice)" "$LOG" >> "$OUT/coach-shots.log" 2>/dev/null || true
    done
    # The coach card and pill in each state, and the morph and collapse end states (coach-<name>-<appearance>.png;
    # names from UISnapshots.coachCardStates).
    for a in light dark; do
      (cd "$HERE" && MEETING_CARD_COACH_CARD_SHOTS="$OUT" scripts/show-fixture.sh meet "$a" 40 >/dev/null 2>&1) || true
      grep -hE "coach card shot" "$LOG" >> "$OUT/coach-card-shots.log" 2>/dev/null || true
    done
    ls "$OUT"
    # Use Zoom/Meet controls review: the card beside each surface it adds or changes (the Muted chip,
    # Settings with the new group off and on, the Muted status menu), light and dark, or fail.
    (cd "$OUT" && ls packet-*.png) > "$OUT/packet-list.txt" 2>/dev/null || true
    missing=0
    for s in card-idle card-listening card-paused card-muted card-nudge-amber card-nudge-rose card-increased-contrast \
             card-saving card-saving-nudge \
             pill-idle pill-muted pill-paused pill-nudge-amber pill-nudge-rose \
             pill-mute-disabled-meet pill-mute-disabled-off pill-mute-disabled-permission morph-end collapse-end; do
      for a in light dark; do
        [[ -s "$OUT/coach-$s-$a.png" ]] || { echo "missing coach-$s-$a.png" >&2; missing=1; }
      done
    done
    for s in chip-muted settings settings-call-controls menu-muted caption-feed-card caption-feed-card-empty; do
      for a in light dark; do
        [[ -s "$OUT/packet-$s-$a.png" ]] || { echo "missing packet-$s-$a.png" >&2; missing=1; }
      done
    done
    [[ $missing == 0 ]]
    ;;
  *) echo "usage: $0 cards <base-swift> <head-swift> <out> | coach <out>" >&2; exit 2 ;;
esac
