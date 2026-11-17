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
  engine (`LocalCoachEngine`), the Core Audio trigger (`CoachTrigger`, `AudioActivitySignal`) and
  `CoachSession`, which reaches capture, rendering and the key store only through protocols.
- `ListenMoreMac` (macOS only): mic capture (AVAudioEngine with voice processing), call audio
  (ScreenCaptureKit audio-only, Chromium helper fallback, Core Audio process tap), the Core Audio
  running-state provider, URLSession transports (ephemeral, no cache or cookies), Keychain store,
  glow overlay and `CoachService`. The host injects the glow style and the Keychain service name.

The call trigger reads Core Audio "is running" flags only (the default input device plus a call
app's output); it never reads window titles. `PrivacyGuardTests` checks this, along with no disk
writes, no printing, the key only through `KeychainStore`, and public log arguments limited to
counters and enums.

## Rule constants

Every tunable number and word list is in one place: [`DefaultConfig.swift`](Sources/ListenMoreCore/DefaultConfig.swift).
They are generic defaults (for example cooldown 20 s, fade 3 s, GPT confidence 0.7, start after
3 s, stop after 30 s). Change them there, with a test, and nowhere else. No recordings, eval
fixtures or example transcripts: tests generate their audio (`Synthetic.swift`) and use
content-free text. Nothing is stored: no history, no summaries.

```sh
swift test                      # Core tests (Linux or macOS); Mac tests too on macOS
LISTEN_MORE_LIVE=1 OPENAI_API_KEY=... swift test --filter ListenMoreLiveTests   # paid, manual
LISTEN_MORE_SCK_PROBE=1 swift test --filter ScreenShareProbeTests              # screen-share probe
```
