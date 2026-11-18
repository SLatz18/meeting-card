# ListenMoreKit

The call coach inside MeetingCard, as a local Swift package (wired in through `swift/project.yml`
`packages:`). This package is the single source of the coach code and its calibrated rule
constants; nothing is vendored from elsewhere and there are no remote dependencies. The coach runs
Swift-native inside the app: no helper process, no interpreter.

- `CWebRTCVAD`: the WebRTC voice activity detector in C (MIT and WebRTC BSD licences in
  `Sources/CWebRTCVAD/LICENSE`).
- `ListenMoreCore` (Foundation only, builds and tests on Linux): config and defaults, VAD and the
  streaming VAD, local rules (interrupt, talk-over, monologue, talk share, prosody), text rules,
  cue policy and cooldowns, the GPT layer (rolling in-memory transcript, judge, budget cap), the
  judge providers (`JudgeProvider`: the GPT judge, the default, or `TypeSafeJudge` for TypeSafe System One), the
  engine (`LocalCoachEngine`), the Core Audio trigger (`CoachTrigger`, `AudioActivitySignal`), the mic
  policy (`MicPlan`, `MicRestartPolicy`, `RoutedMic`) and `CoachSession`, which reaches capture,
  rendering and the key store only through protocols.
- `ListenMoreMac` (macOS only): mic capture (AVAudioEngine, routed by `MicPlan`: no voice processing
  on headphones, the built-in mic with Bluetooth output, voice processing with other-audio ducking
  at its minimum by `MicProcessing` on speakers; reopened on route changes by `RoutedMic` and
  `CoreAudioRoutes`), call audio
  (ScreenCaptureKit audio-only, Chromium helper fallback, Core Audio process tap), the Core Audio
  running-state provider, URLSession transports (ephemeral, no cache or cookies), Keychain store,
  glow overlay and `CoachService`. The host injects the glow style and the Keychain service name.

`judge.provider` (`gpt` | `typesafe`, default `gpt`) picks the judge for the judged cues; a host can
override it per session (`LocalCoachEngine(judgeProvider:)`) and passes the TypeSafe key store
(`judgeKeys:`, `KeychainStore.typeSafeAccount` under its own service). `judge.typesafe` holds the
endpoint, model, confidence floor, timeout, window, error limit, the optional per-call price and
the question criteria. The TypeSafe state is the minimal window only, redacted by `JudgeRedactor`.
`SystemOne` is the confirmed wire format (`questions` keyed by id, `answers` keyed by the same ids,
`usage` tokens); the GPT layer's snapshot sums the tokens, and `CoachSession.judgeStopped` says why
judging stopped after `max_consecutive_errors`. `KeychainStore.sibling(account:)` puts the TypeSafe
key beside the host's OpenAI key.

The call trigger reads Core Audio "is running" flags only (the default input device plus a call
app's output); it never reads window titles. `PrivacyGuardTests` checks this, along with no
printing, the key only through `KeychainStore`, public log arguments limited to counters and
enums, and disk writes: audio never, and text only through `TranscriptFile.swift` (the opt-in saved
transcript: one note per call in the user's folder, its hidden spool beside it while the call runs,
and an optional daily-note line). Its runtime tests show that with saving off nothing reaches disk
and with saving on the call's note is the only file left.

Captions and transcripts (opt-in, host-driven): the realtime sessions' partial and final text reach
the host as `CaptionEvent`s (with a `CostReading` after each billed segment). `LiveTranscript` keeps
a three-line `CaptionBuffer` in memory, labels the streams You and Them (`SpeakerLabels`, per-call
tags), and hands finished lines to `TranscriptRecorder`, which writes nothing unless saving is on.
When the GPT layer stops (cost cap or error) captions stop; local cues continue. The Kit draws no
caption UI: the host renders the lines (MeetingCard: `CaptionFeedView` in its card).

Saved transcripts are Obsidian-ready notes (`CallNote`): YAML properties, a summary placeholder,
the coaching cues linked to their transcript lines by block ID, then the transcript with its gaps
(the coach's Mute, Pause, the call app's mute, transcriber stops and retries, capture reconnects;
`CallConditions`). Every line, gap and cue is appended to the call's spool and synced before the
note is replaced atomically, so `TranscriptMaintenance.recover` can finish a call the app quit
during; the recorder never writes over a note edited since its last write. File names come from a
pattern (`NoteFileName`), the daily-note line is append-only and idempotent (`DailyNote`), and
`TranscriptMaintenance.prune` is the opt-in retention. All of it is plain files and runs on Linux.

A host can pass an optional `CallStateProvider` (to `CoachService`, `CoachSession` or `CoachMonitor`)
reporting each call app's state as started, ended or muted. An ended call stops the session after
`ended_stop_after_s` (3 s) instead of waiting for Core Audio's 30 s stop. The coach releases the
mic on the first poll that sees the ended report, and if the report flips back within those 3 s
only the mic reopens. A muted app holds the
session's capture (the pause path) until unmute; without a provider, Core Audio alone decides.
`CoachSession.setMicMuted` (`CoachService.setMicMuted` / `micMuted`) is the coach's own Mute: it stops the
user's mic engine only, so call audio keeps being captured, captioned as Them and coached, and the
indicator reads `CoachIndicator.micOff`. It lasts until unmuted or the session ends, survives Pause and the
call app's mute, and never touches the call app. `CoachMenu` lists what a host's coach menu offers in each
state: one Start/Stop toggle (`CoachMenuItem.startCoach` / `.stopCoach`), Pause or Resume, `.muteMic` or
`.unmuteMic`, then the status lines and Settings.

`CallControlsProvider` (Core, with fakeable `ZoomAccessibility` / `AppleScriptRunner` backends;
`CallControlsProvider.live(config:)` in ListenMoreMac) is that provider for Zoom (Accessibility:
menu-bar shortcuts only, plus the ⇧⌘A audio toggle's label reduced to a Bool) and Google Meet in
Chrome and Dia (AppleScript: the browser filters tabs to the Meet host and the script returns a
count; Meet mute is not detected, so only Zoom reports `muted`). `CallControlsModel` (`isMuted`, `canMute`,
`muteUnavailableReason`, `toggleMute()`, `onChange`) is a host's Mute control: one Accessibility press on Zoom's own ⇧⌘A item
per call, read back right after; a no-op with a reason (`toggleOff`, `permissionDenied`, `noZoomCall`, `meet`) otherwise. MeetingCard's copy for each reason, and the tooltips and VoiceOver labels, are in `swift/Core/CoachMuteCopy.swift` (no Zoom call hides the control). Off until `isEnabled`; nothing in it prompts, reads windows or titles, or logs. A denied,
revoked or unsupported backend reports nothing for its app. `CallControlsPermissions.request...`
shows the system prompts and is for a host's opt-in toggle only.

## Rule constants

Every tunable number and word list is in one place: [`DefaultConfig.swift`](Sources/ListenMoreCore/DefaultConfig.swift).
They are generic defaults (for example cooldown 20 s, fade 3 s, GPT confidence 0.7, start after
3 s, stop after 30 s, or 3 s after an ended call). Change them there, with a test, and nowhere else. No recordings, eval
fixtures or example transcripts: tests generate their audio (`Synthetic.swift`) and use
content-free text. Nothing is stored unless the user turns on saved transcripts: no history, no
summaries.

```sh
swift test                      # Core tests (Linux or macOS); Mac tests too on macOS
LISTEN_MORE_LIVE=1 OPENAI_API_KEY=... swift test --filter ListenMoreLiveTests   # paid, manual
LISTEN_MORE_LIVE_TYPESAFE=1 TYPESAFE_API_KEY=... swift test --filter TypeSafeLiveTests   # opt-in, manual
LISTEN_MORE_SCK_PROBE=1 swift test --filter ScreenShareProbeTests              # screen-share probe
```
