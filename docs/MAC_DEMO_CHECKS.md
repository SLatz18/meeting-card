# Mac demo checks (run by hand on a real Mac, with the user's go-ahead; not CI tests)

## Always the test build (`--test-id`)
Every check below runs on the **test build**, never the real app, so the real app's privacy grants, settings and
Keychain item are never touched. Get it either way:
- `swift/scripts/build.sh --test-id` installs `~/Applications/MeetingCardSwift-Test.app` (not launched);
  `swift/scripts/build.sh build --test-id` only builds it, in `swift/build/dd-test/Build/Products/Release/`.
- or the unsigned `MeetingCardSwift-Test-app` CI artifact (see [SIGNING_PLAN.md](SIGNING_PLAN.md) for opening it).
  The `MeetingCardSwift-app` artifact is the real app: don't use it for these checks.

The test build has its own identity, and nothing else changes:

| | Real app | Test build |
|---|---|---|
| Bundle ID | `com.slatz.meetingcard.swift` | `com.slatz.meetingcard.swift.test` |
| Name in permission prompts and System Settings | MeetingCardSwift | MeetingCard (Test) |
| UserDefaults domain | `com.slatz.meetingcard.swift` | `com.slatz.meetingcard.swift.test` |
| Keychain service (account `OPENAI_API_KEY`) | `com.slatz.meetingcard.swift.openai` | `com.slatz.meetingcard.swift.test.openai` |
| Log | `~/Library/Logs/MeetingCardSwift.log` | `~/Library/Logs/MeetingCardSwift-Test.log` |
| State | `~/Library/Application Support/MeetingCardSwift/` | `~/Library/Application Support/MeetingCardSwift-Test/` |
| Login item | `~/Applications/MeetingCardSwift.app` only | never |

macOS asks for Microphone and Screen & System Audio Recording again for "MeetingCard (Test)"; grant them there.

**Quit the real app before checking** (`pkill -f MeetingCardSwift.app/Contents/MacOS/MeetingCardSwift`; it doesn't
match the test build). Both builds read the same calendar, so both would show cards, and with the coach on in both,
both would react to the same call. The coach's unified-log entries (`com.listenmore.kit`, K1) also come from a
process named `MeetingCardSwift` in either build.

Clean up after the demo (only the test identity; the real app is untouched):
`tccutil reset Microphone com.slatz.meetingcard.swift.test` (likewise `AudioCapture`, `ScreenCapture`),
`defaults delete com.slatz.meetingcard.swift.test`,
`security delete-generic-password -s com.slatz.meetingcard.swift.test.openai -a OPENAI_API_KEY`,
`rm -rf ~/Library/Logs/MeetingCardSwift-Test.log ~/Library/Application\ Support/MeetingCardSwift-Test`.

## Checks
Prereqs: the test build (above);
coach turned on in MeetingCard Settings (or the coach menu bar menu) with an OpenAI key, except for L1/L2; Microphone and Screen & System Audio Recording granted when
macOS asks. If a call app's bundle ID differs from `capture_targets` in
`swift/Packages/ListenMoreKit/Sources/ListenMoreCore/DefaultConfig.swift` (`osascript -e 'id of app "<App>"'`), note it.

The coach starts from Core Audio state only: the call app producing output and the microphone running, for about 3 s.
With **Use Zoom/Meet controls** on (checks ZC*, MC*, MD*), Zoom's meeting controls and an open Meet tab also end it
about 3 s after the call ends and hold it while Zoom is muted.
The indicator is the chip on a visible card (On → Listening → Paused) and the top line of the coach menu bar menu, which is
always there (Turn On Call Coach while off).

| # | App | Check | How | Pass when |
|---|---|---|---|---|
| Z1 | Zoom desktop | Start / stop | Join a test Zoom meeting with audio | Chip shows Listening within about 3 s; hides about 30 s after leaving |
| Z2 | Zoom desktop | Capture | Another participant talks; the user interrupts | Red glow fires (call audio captured, mic attributed to the user) |
| Z3 | Zoom desktop | Hidden in share | Share the full screen in Zoom while a cue fires | Far side sees no glow; the user sees it |
| C1 | Meet in Chrome | Start / stop | Join Meet in Chrome | Listening within about 3 s; hides about 30 s after the tab closes |
| C2 | Meet in Chrome | Capture | Another participant talks (audio from a Chrome helper) | Call stream has audio; an interrupt fires red |
| C3 | Meet in Chrome | Hidden in share | Present the entire screen from Meet in Chrome | Glow not visible to others |
| D1 | Meet in Dia | Start / stop | Join Meet in Dia | Listening within about 3 s; hides about 30 s after the tab closes |
| D2 | Meet in Dia | Capture | Another participant talks (audio from a Dia helper) | Call stream has audio. If silent, the helper fallback (helper apps, then a process tap) must engage |
| D3 | Meet in Dia | Hidden in share | Present the entire screen from Meet in Dia | Glow not visible to others |
| T1 | Microsoft Teams | Start + capture | Join a Teams meeting with audio | Listening within about 3 s; call stream has audio |
| W1 | Webex | Start + capture | Join a Webex meeting with audio | Same as T1 |
| F1 | FaceTime | Start + capture | Start a FaceTime call | Listening within about 3 s; call stream has audio (expected from `avconferenced`, listed under `audio_bundle_ids`) |
| S1 | Slack huddle | Start + capture | Start a Slack huddle | Listening within about 3 s; call stream has audio. If silent, the helper fallback should engage (Slack is Electron) |
| P1 | All | Skip this call | Click the chip while it shows On | Nothing starts for this call; the next call starts normally |
| P2 | All | Pause | Click the chip while Listening | Chip shows Paused; no glow and no network traffic until Resume |
| M1 | All | Menu while off | Turn the coach off, open its menu bar menu | Shows Call coach: off and Turn On Call Coach; choosing it turns the coach on |
| M2 | All | Menu skip / pause | Open the menu while On, then while Listening | Skip This Call while On; Pause (then Resume) while Listening, matching the chip |
| L1 | Zoom desktop | Local-only | Remove the key in Settings, turn the coach on, join a call and talk over someone | Coach turns on with no key; menu shows GPT cues off: no API key; red glow on talk-over; no traffic to api.openai.com |
| L2 | All | Rejected key | Save a key, then revoke it at OpenAI and relaunch | Settings and the menu flag the key; local cues still fire |
| G1 | All | Focus | A cue fires while typing in another app | Keyboard focus never moves; clicks pass through |
| G2 | All | No sound / cooldown | Trigger the same cue twice in 20 s | One glow, no sound |
| ZC1 | Zoom desktop | Use Zoom/Meet controls: prompt in context | Turn on **Use Zoom/Meet controls** in Settings | macOS asks for Accessibility only now (never before the toggle); Settings names what is still missing; nothing changes for Core Audio checks Z1–Z3 |
| ZC2 | Zoom desktop | Fast stop | With Accessibility granted, join a test meeting, then click Leave (Zoom keeps running) | Listening within about 3 s; chip hides about 3 s after Leave, not 30 s; doesn't restart while Zoom stays open |
| ZC3 | Zoom desktop | Mute pauses | In the meeting, mute (⇧⌘A or the toolbar), wait, unmute | Chip shows **Muted** and the menu says Coach paused while you're muted; no cues and no traffic to api.openai.com while muted; Listening again within about 1 s of unmute |
| ZC4 | Zoom desktop | Pause beats unmute | While muted, click Pause on the chip, then unmute | Chip stays **Paused** until Resume |
| ZC5 | Zoom desktop | Denied / revoked | Deny Accessibility (or remove MeetingCard from it mid-call) | No dialog or error; the coach falls back to the 30 s audio stop |
| MC1 | Meet in Chrome | Prompt in context | Open Chrome, turn the toggle on (or click Request access) | macOS asks "MeetingCard wants to control Google Chrome" only now; Chrome is never launched by MeetingCard |
| MC2 | Meet in Chrome | Fast stop | With Automation granted, join a test Meet (`meet.google.com/xxx-xxxx-xxx`) with other tabs open, then close the Meet tab or click Leave | Listening within about 3 s; chip hides about 3 s after the meeting URL goes away |
| MC3 | Meet in Chrome | Denied | Deny Automation for Chrome (System Settings > Privacy & Security > Automation) | No dialog; Chrome calls fall back to the 30 s audio stop |
| MD1 | Meet in Dia | Scripting check | `osascript -e 'tell application "Dia" to get version'` and `osascript -e 'tell application "Dia" to count (tabs of window 1 whose URL starts with "https://meet.google.com/")'` | Note Dia's version and whether the count works. If it errors, Dia isn't supported: Settings says so and Dia uses the 30 s audio stop |
| MD2 | Meet in Dia | Prompt + fast stop | Open Dia, turn the toggle on, join a test Meet, switch to another Dia space for a minute, then close the Meet tab | One Automation prompt for Dia; the coach keeps listening while the Meet tab is in another space; hides about 3 s after the tab closes |
| MD3 | Meet in Dia | Unsupported or denied | On a Dia where MD1's count errors, or with Automation denied | No dialog; Dia calls fall back to the 30 s audio stop |
| K3 | All | Nothing read is kept | During ZC2–MD2, `log show --predicate 'subsystem == "com.listenmore.kit"' --last 10m` and the MeetingCard log | No meeting or page titles, names, chat, URLs or menu labels anywhere |
| K1 | All | Keychain and logs | Inspect the Keychain and `log show --predicate 'subsystem == "com.listenmore.kit"'` | Key only in the Keychain; no transcript text or key in logs; no files written |
| K2 | All | Keychain caveat | Keychain Access → login → the `com.slatz.meetingcard.swift.test.openai` item | Item is in the **login** keychain. Expected until the app is properly signed (see below), not a failure |

### Keychain caveat (read before K1/K2)
The app asks for the key to be kept "on this device only, while unlocked" (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
The current build stores it in the login keychain, which ignores that setting. The setting only takes effect in a
properly signed build that uses the data-protection keychain (the `keychain-access-groups` entitlement, which needs an
Apple developer account; see [SIGNING_PLAN.md](SIGNING_PLAN.md)). Until then:
- the key does **not** sync to other devices through iCloud Keychain;
- the key **can** move to another Mac in a Time Machine backup or a Migration Assistant transfer.

If that matters for the demo Mac, remove the item after the demo (Keychain Access, or
`security delete-generic-password -s com.slatz.meetingcard.swift.test.openai -a OPENAI_API_KEY`).
