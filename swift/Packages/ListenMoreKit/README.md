# ListenMoreKit

The call coach engine inside MeetingCard, as a local Swift package (wired in through
`swift/project.yml` `packages:`). Vendored from the listen-more prototype's Swift shell; there is
no dependency on that repository.

**Sync point: listen-more `mac/` at `9b5ea23`,** recorded in [`SYNC`](SYNC) with a sha256 of every
vendored file (`Package.swift`, `Sources/`, `Tests/`). Ported from it: the Kit sources and tests
(adapted to MeetingCard: the trigger, runner, chip indicator, glow profile and generic defaults are
MeetingCard's), the type-only config error message, and the Keychain error and ThisDeviceOnly
changes. Not vendored: the standalone menu-bar app (`mac/Sources/ListenMore`) and the prototype's
demo clips, eval data, timelines and screenshots.

Drift check (`swift/scripts/kit-sync.sh`):

```sh
scripts/kit-sync.sh check        # CI runs this: fails, naming the files, if the Kit changed without re-recording
scripts/kit-sync.sh record       # after a deliberate local edit (same upstream commit)
LISTEN_MORE_DIR=~/src/listen-more scripts/kit-sync.sh upstream   # opt-in, local: commits/files behind upstream mac/
scripts/kit-sync.sh record --upstream <sha>                      # after porting upstream up to <sha>
```

CI can't read the private upstream, so it only checks that the files match `SYNC`. When porting,
take code and generic numeric defaults only: no fixtures, eval data, pattern files, or comments
about anyone's call patterns.

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
