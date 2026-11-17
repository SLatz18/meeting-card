# Mac demo checks (run by hand on a real Mac, with the user's go-ahead; not CI tests)

Prereqs: the unsigned `MeetingCardSwift-app` CI artifact (see [SIGNING_PLAN.md](SIGNING_PLAN.md) for opening it);
coach turned on in MeetingCard Settings with an OpenAI key; Microphone and Screen & System Audio Recording granted when
macOS asks. If a call app's bundle ID differs from `capture_targets` in
`swift/Packages/ListenMoreKit/Sources/ListenMoreCore/DefaultConfig.swift` (`osascript -e 'id of app "<App>"'`), note it.

The coach starts from Core Audio state only: the call app producing output and the microphone running, for about 3 s.
The indicator is the chip on a visible card (On → Listening → Paused), or a menu bar item while a session runs with no
card showing.

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
| G1 | All | Focus | A cue fires while typing in another app | Keyboard focus never moves; clicks pass through |
| G2 | All | No sound / cooldown | Trigger the same cue twice in 20 s | One glow, no sound |
| K1 | All | Keychain and logs | Inspect the Keychain and `log show --predicate 'subsystem == "com.listenmore.kit"'` | Key only in the Keychain; no transcript text or key in logs; no files written |
| K2 | All | Keychain caveat | Keychain Access → login → the `com.slatz.meetingcard.swift.openai` item | Item is in the **login** keychain. Expected until the app is properly signed (see below), not a failure |

### Keychain caveat (read before K1/K2)
The app asks for the key to be kept "on this device only, while unlocked" (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
The current build stores it in the login keychain, which ignores that setting. The setting only takes effect in a
properly signed build that uses the data-protection keychain (the `keychain-access-groups` entitlement, which needs an
Apple developer account; see [SIGNING_PLAN.md](SIGNING_PLAN.md)). Until then:
- the key does **not** sync to other devices through iCloud Keychain;
- the key **can** move to another Mac in a Time Machine backup or a Migration Assistant transfer.

If that matters for the demo Mac, remove the item after the demo (Keychain Access, or
`security delete-generic-password -s com.slatz.meetingcard.swift.openai -a OPENAI_API_KEY`).
