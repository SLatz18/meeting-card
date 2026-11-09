# MeetingCardSwift: developer notes

User-facing docs (requirements, gws setup, build, signing) are in the [top-level README](../README.md). This file
covers internals and test seams. The app began as a Python/PyObjC prototype; comments that say "port of
<file>.py" or "like Python" refer to that prototype's behavior, which the Swift code was written to match. Issue numbers in
comments and below (`#4`, `#8`, `#12`, ...) refer to the pre-public tracker, not this repository's issues.

- `Core/` - `MeetingCardCore.framework`, Foundation only: events/links/timing/recheck, Scheduler, gws runner,
  Logger/StateWriter, Coordinator (all controller logic except AppKit). Shared with a future WidgetKit target.
- `App/` - AppKit shell: NSPanel card, drawn icons, timers, test seams.
- `Tests/` - hostless XCTest bundle on Core.
- `project.yml` - xcodegen spec; the `.xcodeproj` is generated, not committed.

Build: `scripts/build.sh` (xcodegen + test + Release build + sign + install to `~/Applications/MeetingCardSwift.app`,
never launches anything). `scripts/build.sh test` = tests only; `scripts/build.sh build` = no install.

Signing: `$SIGN_IDENTITY`, else a `Local Self-Signed` Keychain identity if present, else ad-hoc. No hardened runtime,
no sandbox (it must exec `gws`; no TCC grants needed).

Paths: log `~/Library/Logs/MeetingCardSwift.log`, state `~/Library/Application Support/MeetingCardSwift/last-card.json`
. `--fixture` runs use `MeetingCardSwift-fixture.log` / `MeetingCardSwift-fixture/` instead. Fixture cards stack from the screen's bottom-LEFT corner (live cards: bottom-right) and their title is prefixed `DEMO · `, so a demo card never sits in, or passes for, the live slot. Tests use temp dirs; Core refuses the production paths under XCTest.

Seams: `--fixture <json>`, `--no-poll`, `--no-recheck`, `--snapshot <png>` (CALayer `render(in:)`), `--appearance light|dark`,
`MEETING_CARD_APPEARANCE_FLIP=1` (fixture: flip appearance 0.4s after show),
`MEETING_CARD_BORDER_SWAP=<fixture path>` (fixture: `refresh` the live card with that event after
`MEETING_CARD_BORDER_SWAP_DELAY` s, default 3; logs `border demo: <provider|none>` + `border layers=<n>` per apply),
`MEETING_CARD_SELFTEST=join|ignore` (+ `MEETING_CARD_SELFTEST_DELAY`), `MEETING_CARD_DRY_JOIN=1`.
Status light: `MEETING_CARD_STATUS_LIGHT=1` lets a `--fixture` run drive the light (off in fixture runs otherwise),
`MEETING_CARD_SIDEPULSE=<absolute path>` overrides where the sidepulse CLI is looked for.

Snapshots (`docs/`): `card-{meet,zoom,multilink,countdown,nolink,nextup}-{light,dark}.png`, made with
`scripts/show-fixture.sh <fixture> <light|dark> 2 --snapshot docs/...` (countdown/nolink with `SHIFT=90`, others `SHIFT=none`).

Card look (#12): semantic text (labelColor / secondaryLabelColor), per-appearance fills in `Core/CardStyle.swift`
(`CardPalette`), live light/dark refresh (KVO on `NSApp.effectiveAppearance`), no window shadow, a 1.3pt
provider outline colored by the card's CURRENT link (`CardBorder` in Core, `CardBorder.enabled`, on: Meet conic,
Zoom blue, Teams purple, Webex cyan/green; none for multi-link / no-link / unknown; drawn `BorderLayer`, so
`--snapshot` shows it), panel frame == card rect. Card edge 14pt from the
visibleFrame; 20pt between stacked cards. Snapshots are card-sized (panel frame == card rect).
Keyboard: Return/keypad Enter = Join / Open in Calendar, Esc = Ignore, only after a click or hover (`KeyGate`;
hover arming = `KeyGate.hoverKeysDefault`, on; never while "Joining..."); mouse-exit hands focus back (re-activate the
previous app, then `resignKey()` in place if the panel still holds key; never an order-out/in, which flashed).
Join (video): the button reads "Joining..." for a fixed 8s hold (`OpenWatch.joinHold`), then the card closes;
Open in Calendar and Ignore close at once. While Joining, the log records only gate state changes
(`opening <id>: gate <from>-><to> (<event>)`, from != to) and title sets (`opening <id>: title "<title>"`).

Launch at login (v2.5): on every launch the installed app (`~/Applications/MeetingCardSwift.app`, live, not
`--fixture`) registers itself via `SMAppService.mainApp` if not already enabled, and logs
`login item: <status> (registered|already|error: <e>)`; any other copy (build/dd, scratch) or a fixture run logs
`login item: <status> (skipped: not installed copy|fixture)` and never registers. `requiresApproval` (pending
approval, or switched off by the user) logs `login item: requiresApproval (skipped: needs approval in Login Items)`
and is never re-registered. To turn it off until the #7 settings window exists: System Settings > General >
Login Items, switch MeetingCardSwift off (the app never unregisters or re-enables itself).

Status light (`Core/StatusLight.swift`): Coordinator calls `onCards(count, leadProvider)` at the end of `showCard`
and `closeCard` and after a live `.update` refresh; the lead card is the soonest (`cards.min(by: stackOrder)`).
StatusLight edge-detects on the main thread (0->n On, n->0 Off, lead program changed while on: Retarget = one
`write`, no configure) and runs every decision, file read, marker write and CLI call on one serial queue. Program:
`StatusLight.program(provider:)`, a heartbeat in the `Brand` colors (meet/webex 8 positional colors, zoom/teams one
color, anything else `#FFFFFF`); a valid `StatusLightProgram` override replaces it for every provider. The settings
file: absent = `agent`; present but not a JSON object (the CLI rewrites it non-atomically) = skip the card.
On: retry any pending restore first (skip the card if it still fails), read the prior `led_display`, write
`status-light.json` (state dir) FIRST, `sidepulse battery configure --display custom`, `sidepulse write --device
<root> -- <program>`, one re-check 2s later against the program last written. The marker is the single source of
truth for a pending restore: Off, quit (always, bounded to 3s), launch and the next On call `restorePending`, which
configures the marker's prior only while the settings still say `custom`, retires a stale marker when they do not,
keeps it when the settings are unreadable, and deletes it only after a successful configure. Only those two argv
shapes can be built (`StatusLight.checked`). Each call has a 5s timeout. Log lines: `status light on (prior=<d>)`,
`status light off (prior=<d>)`, `status light: stale marker retired`, `status light skipped: <reason>` (incl.
`restore pending`, `settings unreadable`), `status light: disabled (<reason>)` (once per launch),
`status light: sidepulse <cmd> rc=<n|timeout|launch>`.

## Known gaps

- Status light: quitting while a sidepulse call hangs past the 3s quit budget exits before the restore runs; the marker restores it at the next launch.
- Tall stacks: cards stack upward with no clamp, so 5+ cards (sooner with Next up lines: each adds 18pt) can run past `visibleFrame.maxY` and off the top of the screen. Not built: #8's "+N more" cap (show the first N cards and a "+N more" stub) is the planned fix; no clamping until then.

## Known edge cases (parity notes from the Python prototype)

- HTML entities: minimal table (amp/lt/gt/quot/#39/apos/nbsp + numeric); rare or uppercase entities (`&AMP;`, `&colon;`, `&sol;`) and HTML5 numeric remaps (`&#128;`) stay undecoded. Real Calendar descriptions use `&amp;`.
- Regex: ICU and Python `re` differ at Unicode edges in `\w` (superscripts, combining marks, dotted/dotless i).
- Teams/Webex identity: Swift `String` equality is canonical-equivalence-aware (NFC and NFD forms merge) and decoded newlines are kept; Python compares code points and differs in both.
