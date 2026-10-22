#!/bin/zsh
# Show one fixture card from the BUILT copy (scripts/build.sh build), never the installed app.
#   scripts/show-fixture.sh <fixture> <light|dark> [seconds=60] [extra app args...]
#   e.g. scripts/show-fixture.sh meet dark 60
#        scripts/show-fixture.sh multilink light 3 --snapshot docs/card-multilink-light.png
# <fixture> = name in Tests/Fixtures (meet, zoom, multilink, nolink, ...) or a path.
# SHIFT=<secs> moves the event to start now+SHIFT (default 90 -> "in 2 min"); SHIFT=none keeps
# the fixture's own dates. NEXT=<fixture> (#11) adds a "next" event starting NEXT_GAP min
# (default 10; negative = overlaps) after the card ends, fed through the real poll path. Fixture mode: no gws, no polling, own log
# (~/Library/Logs/MeetingCardSwift-fixture.log); MEETING_CARD_DRY_JOIN=1 so Join/Return only logs.
# Fixture cards appear bottom-LEFT with a "DEMO · " title prefix (live cards: bottom-right, no prefix).
set -euo pipefail
cd "$(dirname "$0")/.."
F="$1"; APPEAR="$2"; SECS="${3:-60}"; shift $(( $# < 3 ? $# : 3 ))
[[ -f "$F" ]] || F="Tests/Fixtures/$F.json"
APP="build/dd/Build/Products/Release/MeetingCardSwift.app/Contents/MacOS/MeetingCardSwift"
[[ -x "$APP" ]] || { echo "no built copy: run scripts/build.sh build" >&2; exit 1; }
TMP="$(mktemp -t mcs-fixture).json"
NF="${NEXT:-}"; [[ -z "$NF" || -f "$NF" ]] || NF="Tests/Fixtures/$NF.json"
NTMP="$(mktemp -t mcs-next).json"
SHIFT="${SHIFT:-90}" NEXT_GAP="${NEXT_GAP:-10}" python3 - "$F" "$TMP" "$NF" "$NTMP" <<'PY'
import json, os, sys, datetime as d
e = json.load(open(sys.argv[1]))
s = os.environ["SHIFT"]
if s != "none" and e.get("start", {}).get("dateTime"):
    st, en = (d.datetime.fromisoformat(e[k]["dateTime"]) for k in ("start", "end"))
    n = d.datetime.now().astimezone().replace(microsecond=0) + d.timedelta(seconds=int(s))
    e["start"]["dateTime"] = n.isoformat()
    e["end"]["dateTime"] = (n + (en - st)).isoformat()
json.dump(e, open(sys.argv[2], "w"))
if sys.argv[3]:
    x = json.load(open(sys.argv[3]))
    xs, xe = (d.datetime.fromisoformat(x[k]["dateTime"]) for k in ("start", "end"))
    ns = d.datetime.fromisoformat(e["end"]["dateTime"]) + d.timedelta(minutes=int(os.environ["NEXT_GAP"]))
    x["start"]["dateTime"] = ns.isoformat()
    x["end"]["dateTime"] = (ns + (xe - xs)).isoformat()
    json.dump(x, open(sys.argv[4], "w"))
PY
EXTRA=(); [[ -n "$NF" ]] && EXTRA=(--next-fixture "$NTMP")
MEETING_CARD_DRY_JOIN=1 "$APP" --fixture "$TMP" --no-poll --appearance "$APPEAR" "${EXTRA[@]}" "$@" &
PID=$!
trap 'kill $PID 2>/dev/null; rm -f "$TMP" "$NTMP"' EXIT
for _ in $(seq 1 $(( SECS * 10 ))); do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
