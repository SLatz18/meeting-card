# ListenMoreKit

The call coach engine inside MeetingCard, as a local Swift package (wired in through
`swift/project.yml` `packages:`). Vendored from the listen-more prototype's Swift shell (`mac/`
at `1a997e7`); there is no dependency on that repository.

- `ListenMoreCore` (Foundation only, builds and tests on Linux): config and generic defaults,
  voice activity detection, local rules (interrupt, talk-over, monologue, talk share, tone flags),
  cue policy and cooldown, the GPT layer (rolling in-memory transcript, judge prompt, budget cap),
  the audio-activity trigger, the capture/stream lifecycle (`CoachRunner`), glow math.
- `ListenMoreMac` (macOS only): mic capture (AVAudioEngine with voice processing), call audio
  (ScreenCaptureKit audio-only, Chromium helper fallback, Core Audio process tap), Core Audio
  running-state provider, OpenAI realtime transcription and Responses judge, Keychain store, glow
  overlay, `CoachService`.

Ships generic defaults only (`DefaultConfig.swift`: cooldown 20 s, fade 3 s, GPT confidence 0.7,
start after 3 s, stop after 30 s). No recordings, eval fixtures or example transcripts: tests
generate their audio and use content-free text. Nothing is stored: no history, no summaries.

```sh
swift test                      # Core tests (Linux or macOS); Mac tests too on macOS
LISTEN_MORE_LIVE=1 OPENAI_API_KEY=... swift test --filter ListenMoreLiveTests   # paid, manual
LISTEN_MORE_SCK_PROBE=1 swift test --filter ScreenShareProbeTests              # screen-share probe
```
