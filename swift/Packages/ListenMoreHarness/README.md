# ListenMoreHarness

A standalone voice harness for the call coach. It drives ListenMoreCore's real pipeline
(`CoachSession` → `LocalCoachEngine` → `GptLayer` → `LiveTranscriber`, with captions and the opt-in
transcript through `LiveTranscript` and `FileTranscriptStore`) with two input streams, **You** on the
mic and **Them** on the call. It needs no Mac, no call and no audio devices: the mic, call capture and
Core Audio state are in-memory fakes behind the Kit's protocols. Not part of the app.

Each run scores three things per scenario and writes one results table:

- **Transcription**: word error rate against the script, per stream (You, Them) and per scenario, plus
  caption latency: for each transcribed speech segment, from the end of its speech (the commit, less
  the VAD hangover) to its final transcript. Live lines are committed in pieces at pauses, so this is
  per segment, never per line.
- **Speaker identification**: every transcribed segment attributed to You or Them by audio timing (the
  script line whose span holds the segment's speech end and most of its words); correct means the right
  stream's transcriber, the right speaker on its caption and the right label in the caption feed. A
  segment is only matched against lines whose audio could reach a transcriber (not You's lines spoken
  while muted, nothing inside a Pause), and any wrong one is named in the report. With an accuracy
  figure, and what happens with two different Them voices.
- **Coaching**: every cue (type, level, timing, source) against the cue rules: expected cues fire, no
  false cues (including right after unmute), and none while paused or muted.

## Offline (default, deterministic, runs in CI)

```sh
cd swift/Packages/ListenMoreHarness
swift run lm-harness                  # all scenarios; prints where results.md went
swift run lm-harness --scenario mute-unmute --out /tmp/harness
swift test                            # scenario suite, checks-catch-regressions tests, guards
swift run lm-harness --voices espeak  # diagnostic: real word timing and pauses from a local espeak-ng
```

Linux needs Swift 6.2 and `libssl-dev pkg-config` (live mode's TLS); macOS needs Xcode 26. Offline
audio is generated at run time (a voiced harmonic signal per voice, the Kit's `speechish`
construction), transcription is a wire-level stand-in for the OpenAI realtime socket that answers each
commit with the script text of the lines whose audio it actually received, and the judge always says
`none`. The engine's queue, the GPT layer's loop and caption delivery are stepped together 20 ms at a
time on a simulated clock, so cues and captions land at the same frame on every run. Offline WER is 0
by construction: it checks the plumbing (what reached which transcriber, what came back, how it was
labelled), not speech recognition. `--voices espeak` speaks the script with a local `espeak-ng`
instead (free, deterministic, piped through memory): real word timing and pauses, for timing effects
the synthetic signal can't show, such as a reply decided before it ends. espeak's comma pauses (about
0.16 s) are shorter than the VAD hangover, so it doesn't show re-onsets after commas; OpenAI TTS does.

## Live (dev box or the owner-only workflow)

```sh
cd swift/Packages/ListenMoreHarness
read -rs OPENAI_API_KEY && export OPENAI_API_KEY   # typed, not echoed, not in shell history
swift run lm-harness --live                        # optionally --scenario NAME --out DIR --judge --tts-model MODEL
```

OpenAI TTS speaks every line (stock voices: `alloy` for You, `coral` and `onyx` for the two Them
voices), then the clips run through real realtime transcription in real time, so latencies are real.
The not_listening judge is **off by default live (0 judge calls)**; `--judge` turns it on (its verdicts
are informational, scored only near the reply that triggered them). Every other rule, including
missed question, is a transcript or local rule and runs either way. The key is read from `OPENAI_API_KEY` only: `lm-harness` refuses an argument that
looks like a key, never prints it, and every output file is scrubbed (a match fails the run). Clips
stay in memory. The whole set is about 7 minutes of audio; `cost-log.jsonl` records TTS characters and
seconds, transcription billed seconds and dollars, and judge calls, tokens and dollars (log only, no
harness cap; the engine's own `gpt.budget_usd_per_call` still applies per scenario). Each engine (Pause
and the call app's mute restart it) meters from 0; the log sums them. A failed judge call is logged
by class only (`HTTP 401 incorrect_hostname`, `URLError -1001`). A key whose project needs a regional
host gets one `401 incorrect_hostname` on the first judge call of the run: the judge retries on the
host OpenAI names and every later judge in the process starts there (`LearnedHosts`). A judge call
cancelled when the engine stops (Pause, the call app's mute, the end of the call) is counted as
`cancelled_at_engine_stop`, not as a failure.

On Linux, live HTTPS goes through FoundationNetworking and the system libcurl. libcurl 8.11 and newer
abort a process that releases a URLSession ("_MultiHandle deallocated with non-zero retain count",
swift-corelibs-foundation #5203), so the harness keeps one URLSession for the whole run and never
releases it; it works with distro curl 8.5 and 8.14 alike. The realtime socket doesn't use libcurl.

On GitHub: Actions → **Voice harness live (manual, paid)** → Run workflow (optionally one scenario, and
the judge input, off by default). The container is pinned by digest and the actions by commit SHA.
It runs only by manual dispatch, only when the repository owner both started and triggered the run
(a collaborator's re-run is skipped), one at a time, in the `openai-live` environment (restricted to
main), never on push, pull requests or forks, and uploads only the results table, `results.json` and
the cost log. Keep `OPENAI_API_KEY` as a secret of the `openai-live` environment, not a repository
secret, so the main-only restriction guards it.

## Output

`results.md` (the scenario × transcription / speaker ID / coaching table, then per scenario the
expected vs actual cues and every check), `results.json` and `cost-log.jsonl`, in `--out` (default: a
new folder under the system temp directory). Never committed. Each scenario gets a private temp
directory (mode 0700, named with the harness's pid) for the opt-in transcript; it is wiped at the end,
a run sweeps folders a crashed run left behind (dead pid and untouched for five minutes), and a disk audit fails the run if an audio-like file
appeared anywhere else (temp dir, the repository, the home folder's top level).

For each missed or false interrupt, the report adds a diagnostic: the run's own audio replayed through
`LocalLayer` with the same Mutes and Pauses, saying whether the local rule raised the cut-in on that
audio, where You's onsets fell, whether Them were talking, and Them's longest gap in the next 0.6 s
(the cut-in rule drops a cut-in when Them pause for more than about 0.16 s in that span).

## Scenarios

| Scenario | What it asserts |
|---|---|
| `interruption` | A 0.4 s "Yeah." over Them gives no cue; You cutting in while Them keep talking 3.5 s gives one `interrupt` about 1.2 s after You start. |
| `monologue` | You hold the floor for over 60 s after Them ask for the plan: one soft `monologue` cue at the 60 s mark. |
| `missed-question` | A question You answer ("Yes, ...") gives no cue; one You talk past gives one soft `missed_question`. Save transcripts on, then Delete Transcript mid-call: the file is gone and stays gone (T4). |
| `mute-unmute` | The coach's Mute: zero mic samples reach the engine and zero ME audio is sent, though the fake device keeps offering audio; no You lines in captions or the saved file; Them captions continue; You cutting in and Them asking a question while muted give nothing; You's first words back start 0.3 s after Unmute, inside `local.unmute_grace_s`, and give no cue though they run on past the grace through comma pauses (the exemption ends when You pause 0.5 s, Them start a new utterance, or 3 s past the grace); a real cut-in later gives one `interrupt`. Saved transcript: one `Call … .md`, mode 0600, times and labels, deleted at teardown (T3, T4). |
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
script. Offline windows are tight (about −0.3 to +0.6 s). Live windows allow for real VAD and
transcription latency: cues that wait on a transcript get 1.5 s after the speech (about twice the
0.66-0.80 s the first live run measured), and the session's stop gets two polls (the trigger needs one
poll to see the call app's audio off and, on the live wall clock, can need one more to see 30 s have
passed). A missed question can fire as soon as `question_decide_words` words of the reply are
transcribed, which with pauses (live, espeak) is before the reply ends; with the synthetic signal, one
segment per line, it is due at the reply's end. A tolerated cue (a judge verdict on a reply,
a borderline trailing cut-in, a counter-question) is tolerated only in a window around the line that
justifies it, never for a cue type across the scenario. A cut-in needs Them to keep talking through
its first 0.6 s of overlap (gaps up to about 0.16 s); where Them's own audio, measured by clip energy,
pauses longer there, their restarts are speaker switches and the talk-over rule may raise the red cue
instead, so `talk_over` is accepted for that cut-in, in a window after Them stop.

## Limits

- No echo or bleed between streams: each stream is clean. The engine attributes by stream, so a line
  can only be misattributed if routing is (or if the scoring matches a segment to the wrong line). Offline, the stand-in server answers each socket with its own
  stream's lines, so attribution is right by construction there; the `stream-routing` check (loud
  audio on the wrong transcriber) is what tests routing offline. Live, attribution is measured on
  real transcripts.
- Which socket is You and which is Them is taken from the order `GptLayer` opens them (You first).
- The oracle covers what the scenarios exercise; heat (`aggressive`) and talk share can't fire in calls
  this short (`heat_suppress_first_s` is 300 s, `talk_share_min_speech_s` 300 s) and are expected never to.
- Live transcription passes under 35 % WER.
