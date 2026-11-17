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
`tccutil reset Microphone com.slatz.meetingcard.swift.test` (likewise `AudioCapture`, `ScreenCapture`, and `Accessibility`, `AppleEvents` after the Zoom/Meet checks),
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
about 3 s after the call ends and hold it while Zoom is muted. **Meet mute is not detected** (in Chrome or Dia): it
isn't readable without page content, so muting in Meet never pauses the coach (MC4). Only Zoom's mute does.
The indicator is the coach card (the reminder card morphs into it near the camera; it can be minimized to a pill), showing
Coach on → Coach on, listening → Coach paused, and the top line of the coach menu bar menu, which is always there (Turn On
Call Coach while off).

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
| P1 | All | Stop coach | Click **Stop coach** on the coach card (or the pill's Stop) while it shows Coach on, then in another call while listening | The card goes away; VoiceOver says "Call coach is off for the rest of this call."; nothing restarts for this call; the next call starts normally |
| P2 | All | Pause | Click Pause on the coach card while listening | Status line shows Coach paused; no glow and no network traffic until Resume |
| M1 | All | Menu while off | Turn the coach off, open its menu bar menu | Shows Call coach: off and Turn On Call Coach; choosing it turns the coach on |
| M2 | All | Menu stop / pause | Open the menu while Coach on, then while listening | Stop coach in both; Pause (then Resume) while listening, matching the coach card |
| L1 | Zoom desktop | Local-only | Remove the key in Settings, turn the coach on, join a call and talk over someone | Coach turns on with no key; menu shows GPT cues off: no API key; red glow on talk-over; no traffic to api.openai.com |
| L2 | All | Rejected key | Save a key, then revoke it at OpenAI and relaunch | Settings and the menu flag the key; local cues still fire |
| G1 | All | Focus | A cue fires while typing in another app | Keyboard focus never moves; clicks pass through |
| G2 | All | No sound / cooldown | Trigger the same cue twice in 20 s | One glow, no sound |
| ZC1 | Zoom desktop | Use Zoom/Meet controls: prompt in context | Turn on **Use Zoom/Meet controls** in Settings | macOS asks for Accessibility only now (never before the toggle); the Settings help says it can also press Zoom's own Mute button; Settings names what is still missing; nothing changes for Core Audio checks Z1–Z3 |
| ZC2 | Zoom desktop | Fast stop | With Accessibility granted, join a test meeting, then click Leave (Zoom keeps running) | Listening within about 3 s; chip hides about 3 s after Leave, not 30 s; doesn't restart while Zoom stays open |
| ZC3 | Zoom desktop | Mute pauses | In the meeting, mute (⇧⌘A or the toolbar), wait, unmute | Chip shows **Muted** and the menu says Coach paused while you're muted; no cues and no traffic to api.openai.com while muted; Listening again within about 1 s of unmute |
| ZC4 | Zoom desktop | Pause beats unmute | While muted, click Pause on the chip, then unmute | Chip stays **Paused** until Resume |
| ZC5 | Zoom desktop | Denied / revoked | Deny Accessibility (or remove MeetingCard from it mid-call) | No dialog or error; the coach falls back to the 30 s audio stop |
| MZ1 | Zoom desktop | Press Mute in a Zoom call | In a Zoom meeting with Accessibility granted and audio live, press the coach's Mute control (once a surface hosts `CallControlsModel`, e.g. #13e's card or pill), then press it again | One press mutes Zoom (Zoom's own button and Meeting menu show Unmute audio; the chip shows **Muted**); the second unmutes. Each press toggles exactly once. Tooltip: Mute your mic / Unmute your mic; VoiceOver: Mute your Zoom mic / Unmute your Zoom mic. No keystroke reaches the front app (type in another app meanwhile: nothing extra appears) |
| MZ2 | Zoom desktop | Mute control unavailable | Press it with Use Zoom/Meet controls off, with Accessibility denied, and with no Zoom meeting | Nothing happens in Zoom. Toggle off: disabled, tooltip Turn on "Use Zoom/Meet controls" in Settings to mute here. Permission denied: disabled, tooltip Allow MeetingCard in Privacy & Security to mute here. No Zoom call: the control is hidden (no tooltip) |
| MZ3 | Meet (Chrome or Dia) | No Mute action for Meet | In a Meet call, look at the coach's Mute control | It's disabled with tooltip Mute from the Meet window and VoiceOver label Mute unavailable. Mute from the Meet window.; pressing it does nothing; the coach keeps listening (it never mutes by stopping its own capture) |
| MC1 | Meet in Chrome | Prompt in context | Open Chrome, turn the toggle on (or click Request access) | macOS asks only now, naming the app correctly: "MeetingCard (Test)" wants access to control "Google Chrome" (the real app would say "MeetingCardSwift"), with MeetingCard's usage text; Chrome is never launched by MeetingCard |
| MC2 | Meet in Chrome | Fast stop | With Automation granted, join a test Meet (`meet.google.com/xxx-xxxx-xxx`) with other tabs open, then close the Meet tab or click Leave | Listening within about 3 s; chip hides about 3 s after the meeting URL goes away |
| MC3 | Meet in Chrome | Denied | Deny Automation for Chrome (System Settings > Privacy & Security > Automation) | No dialog; Chrome calls fall back to the 30 s audio stop |
| MC4 | Meet in Chrome | Meet mute is not detected | In the Meet call, mute in Meet for 30 s, then unmute | Expected: the chip stays **Listening** (never **Muted**) and cues can still fire; Meet mute is not detected, by design |
| MD1 | Meet in Dia | Scripting check and prompt | (a) In Terminal: `osascript -e 'tell application "Dia" to get version'` and `osascript -e 'tell application "Dia" to count (tabs of window 1 whose URL starts with "https://meet.google.com/")'`. (b) With Dia open and MeetingCard not yet allowed for Dia (`tccutil reset AppleEvents com.slatz.meetingcard.swift.test` first if needed), turn on **Use Zoom/Meet controls** in MeetingCard Settings (or click Request access) | (a) Note Dia's version and whether the count works; if it errors, Dia isn't supported: Settings says so and Dia uses the 30 s audio stop. (b) The Automation prompt names MeetingCard correctly: it says "MeetingCard (Test)" wants access to control "Dia" (the test build's name; the real app would say "MeetingCardSwift"; not Terminal, osascript or a helper), shows MeetingCard's text ("With Use Zoom/Meet controls on, MeetingCard asks your browser only whether a Google Meet call tab is open…"), and MeetingCard (Test) then appears under Dia in System Settings > Privacy & Security > Automation. Note any other name |
| MD2 | Meet in Dia | Fast stop | With Dia allowed in MD1, join a test Meet, switch to another Dia space for a minute, then close the Meet tab | No further prompt; the coach keeps listening while the Meet tab is in another space (muting in Meet doesn't pause it: Meet mute is not detected); hides about 3 s after the tab closes |
| MD3 | Meet in Dia | Unsupported or denied | On a Dia where MD1's count errors, or with Automation denied | No dialog; Dia calls fall back to the 30 s audio stop |
| CC1 | Zoom desktop | Morph and glide | Click Join on a card for a test Zoom meeting, then once with Reduce Motion on (System Settings > Accessibility > Display) | The card morphs in place into the coach card, then glides to top-center under the menu bar (and notch). With Reduce Motion it fades out and back in at that spot instead |
| CC2 | All | Placement | With the call window on the built-in display, then on an external display (after the first cue), then drag the card and start another call | Top-center of the display the call is on (under the camera on the built-in display); the dragged spot is kept for the next call and the card never leaves the visible screen |
| CC3 | Zoom desktop | Call bar clearance (UNVERIFIED 52 pt) | In a full-screen Zoom meeting with its floating top meeting controls showing, measure the gap between the controls' bottom edge and the coach card's top edge (Screenshot ⇧⌘4, read the pixel distance at 1x) | The card clears Zoom's controls by about 12 pt. Note the measured controls height so `CardStyle.Coach.callBarClearance` (52 pt, an estimate) can be set to it |
| CC4 | Zoom desktop | Mute from the card | With **Use Zoom/Meet controls** on and Accessibility granted, click Mute on the coach card, then Unmute | Zoom itself mutes and unmutes (its toolbar mic changes); the status line shows Coach paused while you're muted; MeetingCard's own capture never mutes the call |
| CC5 | All | Mute disabled | On Meet; with the toggle off; with Accessibility denied | Mute is dimmed; its tooltip reads "Mute from the Meet window", "Turn on "Use Zoom/Meet controls" in Settings to mute here." and "Allow MeetingCard in Privacy & Security to mute here." |
| CC6 | All | Pill and nudges | Minimize the card, then trigger an amber and a red cue, with VoiceOver on | The pill tints amber, then rose, and widens to show the nudge words for about 4.5 s; VoiceOver reads the nudge line; Expand brings the card back |
| CC7 | Zoom desktop | Hidden in share | Share the full screen in Zoom while the card, the pill, a nudge and a morph (Join) show | The far side never sees the coach card in any state |
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
