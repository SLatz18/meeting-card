# ListenMoreHarness

A standalone voice harness for the call coach. It drives ListenMoreCore's real pipeline
(`CoachSession` → `LocalCoachEngine` → `GptLayer` → `LiveTranscriber`, with captions and the opt-in
transcript through `LiveTranscript` and `FileTranscriptStore`) with two input streams, **You** on the
mic and **Them** on the call. It needs no Mac, no call and no audio devices: the mic, call capture and
Core Audio state are in-memory fakes behind the Kit's protocols. Not part of the app.

Each run scores three things per scenario and writes one results table:

- **Transcription**: word error rate against the script, per stream (You, Them) and per scenario, plus
  caption latency (end of speech to final caption).
- **Speaker identification**: every caption line attributed to You or Them, with an accuracy figure, and
  what happens with two different Them voices.
- **Coaching**: every cue (type, level, timing, source) against the cue rules: expected cues fire, no
  false cues (including right after unmute), and none while paused or muted.

## Offline (default, deterministic, runs in CI)

```sh
cd swift/Packages/ListenMoreHarness
swift run lm-harness                  # all scenarios; prints where results.md went
swift run lm-harness --scenario mute-unmute --out /tmp/harness
swift test                            # scenario suite, checks-catch-regressions tests, guards
```

Linux needs Swift 6.2 and `libssl-dev pkg-config` (live mode's TLS); macOS needs Xcode 26. Offline
audio is generated at run time (a voiced harmonic signal per voice, the Kit's `speechish`
construction), transcription is a wire-level stand-in for the OpenAI realtime socket that answers each
commit with the script text of the lines whose audio it actually received, and the judge always says
`none`. The engine's queue, the GPT layer's loop and caption delivery are stepped together 20 ms at a
time on a simulated clock, so cues and captions land at the same frame on every run. Offline WER is 0
by construction: it checks the plumbing (what reached which transcriber, what came back, how it was
labelled), not speech recognition.

## Live (dev box or the owner-only workflow)

```sh
cd swift/Packages/ListenMoreHarness
read -rs OPENAI_API_KEY && export OPENAI_API_KEY   # typed, not echoed, not in shell history
swift run lm-harness --live                        # optionally --scenario NAME --out DIR --tts-model MODEL
```

OpenAI TTS speaks every line (stock voices: `alloy` for You, `coral` and `onyx` for the two Them
voices), then the clips run through real realtime transcription and the real judge in real time, so
latencies are real. The key is read from `OPENAI_API_KEY` only: `lm-harness` refuses an argument that
looks like a key, never prints it, and every output file is scrubbed (a match fails the run). Clips
stay in memory. The whole set is about 7 minutes of audio; `cost-log.jsonl` records TTS characters and
seconds, transcription billed seconds and dollars, and judge calls, tokens and dollars (log only, no
harness cap; the engine's own `gpt.budget_usd_per_call` still applies per scenario).

On GitHub: Actions → **Voice harness live (manual, paid)** → Run workflow (optionally one scenario).
It runs only by manual dispatch, only when the repository owner both started and triggered the run
(a collaborator's re-run is skipped), one at a time, in the `openai-live` environment (restricted to
main), never on push, pull requests or forks, and uploads only the results table, `results.json` and
the cost log. Keep `OPENAI_API_KEY` as a secret of the `openai-live` environment, not a repository
secret, so the main-only restriction guards it.

## Output

`results.md` (the scenario × transcription / speaker ID / coaching table, then per scenario the
expected vs actual cues and every check), `results.json` and `cost-log.jsonl`, in `--out` (default: a
new folder under the system temp directory). Never committed. Each scenario gets a private temp
directory (mode 0700) for the opt-in transcript; it is wiped at the end, and a disk audit fails the
run if an audio-like file appeared anywhere else (temp dir, the repository, the home folder's top level).

## Scenarios

| Scenario | What it asserts |
|---|---|
| `interruption` | A 0.4 s "Yeah." over Them gives no cue; You cutting in while Them keep talking 3.5 s gives one `interrupt` about 1.2 s after You start. |
| `monologue` | You hold the floor for over 60 s after Them ask for the plan: one soft `monologue` cue at the 60 s mark. |
| `missed-question` | A question You answer ("Yes, ...") gives no cue; one You talk past gives one soft `missed_question`. Save transcripts on, then Delete Transcript mid-call: the file is gone and stays gone (T4). |
| `mute-unmute` | The coach's Mute: zero mic samples reach the engine and zero ME audio is sent, though the fake device keeps offering audio; no You lines in captions or the saved file; Them captions continue; You cutting in and Them asking a question while muted give nothing; You speaking 0.3 s after Unmute, inside `local.unmute_grace_s`, gives no cue; a real cut-in after the grace gives one `interrupt`. Saved transcript: one `Call … .md`, mode 0600, times and labels, deleted at teardown (T3, T4). |
| `pause` | One `interrupt` before Pause. Paused: no frames reach the engine on either stream, no transcription traffic, no captions, no cues; the engine stops at Pause and restarts at Resume. A second `interrupt` after Resume, more than the 20 s cooldown after the first in session time, though the restarted engine's clock is back near 0. |
| `silence-to-stop` | The call app stops running audio: the session ends `trigger.stop_after_s` (30 s) later, not sooner; captions are cleared; no cues during the silence; keep-nothing (saving off) writes nothing (T2). |
| `two-them-voices` | Two distinct Them voices on the call stream. The engine attributes by stream (no diarization), so the report says **merged as Them**. Them renamed mid-call: caption rows and the saved file use the tag; the next call is back to Them (X4). |
| `no-key` | No key: local cues only (the `interrupt` still fires), captions unavailable, no transcription or judge traffic (X3). |
| `cost-cap` | A tiny `gpt.budget_usd_per_call`: transcription stops at the cap, captions say so, the local `interrupt` still fires (T5). |

Every scenario also checks You/Them attribution, the caption feed (at most three lines labelled You
and Them, cleared when the call ends: X1), stream routing (no loud audio on the wrong transcriber),
persistence (keep-nothing, or exactly one opt-in transcript deleted at teardown), the disk audit, and
offline, that no lockstep barrier timed out. `MutationTests` show the checks have teeth: removing the
unmute grace, a Mute or Pause that does nothing, a wrong cut-in, monologue, question or stop
threshold, an ignored speaker tag or a transcript kept after Delete each fail the named check.

## How the cue rules are checked

`CueOracle` restates the rules from the config's constants (cut-in overlap, continue and backchannel
lengths, a question just before a cut-in, the unmute grace; monologue soft/strong with the relative
and how/why thresholds; missed question with direct answers, shared words, decide words and end of
turn; the cooldowns; the closing-phrase quiet; pause and mute gates) and applies them to the realized
script. Offline windows are tight (about −0.3 to +0.6 s); live windows allow for real VAD and
transcription latency. Live, `not_listening` comes from a model and is reported as informational.

## Limits

- No echo or bleed between streams: each stream is clean. Speaker attribution is by stream, so it
  can only be wrong if routing is. Offline, the stand-in server answers each socket with its own
  stream's lines, so attribution is right by construction there; the `stream-routing` check (loud
  audio on the wrong transcriber) is what tests routing offline. Live, attribution is measured on
  real transcripts.
- Which socket is You and which is Them is taken from the order `GptLayer` opens them (You first).
- The oracle covers what the scenarios exercise; heat (`aggressive`) and talk share can't fire in calls
  this short (`heat_suppress_first_s` is 300 s, `talk_share_min_speech_s` 300 s) and are expected never to.
- Live transcription passes under 35 % WER. A live line can be split across captions; fragments match
  the script by word share near the time they arrived.
