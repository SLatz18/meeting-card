# MeetingCardSwift: developer notes

User-facing docs (requirements, gws setup, build, signing) are in the [top-level README](../README.md). This file
covers internals and test seams. The app began as a Python/PyObjC prototype; comments that say "port of
<file>.py" or "like Python" refer to that prototype's behavior, which the Swift code was written to match. Issue numbers in
comments and below (`#4`, `#8`, `#12`, ...) refer to the pre-public tracker, not this repository's issues.

- `Core/` - `MeetingCardCore.framework`, Foundation only: events/links/timing/recheck, Scheduler, gws runner,
  Logger/StateWriter, Coordinator (all controller logic except AppKit). Shared with a future WidgetKit target.
- `App/` - AppKit shell: NSPanel card, drawn icons, timers, test seams.
- `Tests/` - hostless XCTest bundle on Core.
- `Packages/ListenMoreKit/` - the call coach engine (local Swift package; Core tests run on Linux too).
- `project.yml` - xcodegen spec; the `.xcodeproj` is generated, not committed.

Build: `scripts/build.sh` (xcodegen + test + Release build + sign + install to `~/Applications/MeetingCardSwift.app`,
never launches anything). `scripts/build.sh test` = tests only; `scripts/build.sh build` = no install.
`--test-id` (any mode) builds the test identity: bundle id `com.slatz.meetingcard.swift.test`, named "MeetingCard (Test)",
Release in `build/dd-test`, install to `~/Applications/MeetingCardSwift-Test.app`. It overrides the `MEETINGCARD_APP_ID` /
`MEETINGCARD_APP_NAME` build settings; the Keychain service and other bundle-scoped names come from
`Bundle.main.bundleIdentifier` (`Core/AppIdentity.swift`): Keychain service, defaults suites, log and Application Support
names (`MeetingCardSwift-Test`), and the login item (only the shipping identity registers). It never touches the real
app's Keychain item, defaults, files or privacy grants. Mac hand checks use it ([MAC_DEMO_CHECKS.md](../docs/MAC_DEMO_CHECKS.md)).

Signing: `$SIGN_IDENTITY`, else a `Local Self-Signed` Keychain identity if present, else ad-hoc. No hardened runtime,
no sandbox (it must exec `gws`; no TCC grants needed unless the call coach is turned on).

Paths: log `~/Library/Logs/MeetingCardSwift.log`, state `~/Library/Application Support/MeetingCardSwift/last-card.json`
. `--fixture` runs use `MeetingCardSwift-fixture.log` / `MeetingCardSwift-fixture/` instead. A `--test-id` build uses `MeetingCardSwift-Test` (and `MeetingCardSwift-Test-fixture`) in place of `MeetingCardSwift`. Fixture cards stack from the screen's bottom-LEFT corner (live cards: bottom-right) and their title is prefixed `DEMO · `, so a demo card never sits in, or passes for, the live slot. Tests use temp dirs; Core refuses the production paths under XCTest.

Seams: `--fixture <json>`, `--no-poll`, `--no-recheck`, `--snapshot <png>` (CALayer `render(in:)`), `--appearance light|dark`,
`MEETING_CARD_APPEARANCE_FLIP=1` (fixture: flip appearance 0.4s after show),
`MEETING_CARD_BORDER_SWAP=<fixture path>` (fixture: `refresh` the live card with that event after
`MEETING_CARD_BORDER_SWAP_DELAY` s, default 3; logs `border demo: <provider|none>` + `border layers=<n>` per apply),
`MEETING_CARD_SELFTEST=join|ignore` (+ `MEETING_CARD_SELFTEST_DELAY`), `MEETING_CARD_DRY_JOIN=1`.
Coach seams (fixture runs only; the coach itself is never created on a fixture run):
`MEETING_CARD_COACH_CHIP=on|listening|paused|muted` (that chip on the card), `MEETING_CARD_COACH_SHOTS=<dir>` (write glow,
Settings, Settings with Use Zoom/Meet controls on, onboarding and menu PNGs, then quit). `scripts/snapshots.sh` renders them, and CI pixel-compares every reminder
card at the base and head revisions (`scripts/compare-snapshots.py`).

Call coach (opt-in, off by default): `App/Coach*.swift` (controller, chip, Settings, copy) on top of ListenMoreKit.
Design tokens in `Core/Theme.swift`: `CardStyle` holds the reminder card's typography, color roles, radii, spacing, strokes, material and light/dark values. The card reads it, and every coach surface (chip, glow, Settings, onboarding, status menu) derives from it through `Theme`; the Kit gets its glow colors and shape as a `CoachStyle` built from these tokens. `scripts/snapshots.sh coach` also writes `packet-*.png` (listed in `packet-list.txt`): the card beside each coach surface, light and dark, and fails if a Use Zoom/Meet controls packet (`chip-muted`, `settings`, `settings-call-controls`, `menu-muted`) is missing. The Use Zoom/Meet controls group and the Muted state read `Theme.CallControls`.
Needs Microphone, System Audio Recording and Screen Recording only once the user turns the coach on. "Use Zoom/Meet
controls" (off by default) adds Accessibility (Zoom) and Automation (Chrome, Dia), asked for only when that toggle is
turned on (or from its Request access button).

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

## Known gaps

- Coach mic and transcription (a Mac test showed a call with no mic and a transcription layer that stopped 3 s in): a failed first mic open is now logged and retried (at most three tries per 30 s while the session runs and isn't muted), and a short or rejected transcription commit no longer stops the layer. Not yet known: which step failed in that test, and whether a built-in mic that delivers nothing was a closed lid or voice processing. The set-aside line now carries buffer counts to tell them apart; a failed open's step and status aren't in the log yet. The coach's diagnostics log is not on `main`, so these events reach the system log only (subsystem `com.listenmore.kit`), and a refused commit is not logged at all, until that log lands.
- Tall stacks: cards stack upward with no clamp, so 5+ cards (sooner with Next up lines: each adds 18pt) can run past `visibleFrame.maxY` and off the top of the screen. Not built: #8's "+N more" cap (show the first N cards and a "+N more" stub) is the planned fix; no clamping until then.

## Known edge cases (parity notes from the Python prototype)

- HTML entities: minimal table (amp/lt/gt/quot/#39/apos/nbsp + numeric); rare or uppercase entities (`&AMP;`, `&colon;`, `&sol;`) and HTML5 numeric remaps (`&#128;`) stay undecoded. Real Calendar descriptions use `&amp;`.
- Regex: ICU and Python `re` differ at Unicode edges in `\w` (superscripts, combining marks, dotted/dotless i).
- Teams/Webex identity: Swift `String` equality is canonical-equivalence-aware (NFC and NFD forms merge) and decoded newlines are kept; Python compares code points and differs in both.
