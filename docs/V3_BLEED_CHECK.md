# V3: bleed check against the call stream (design note, not built)

**Status: rejected for building until the V1 hand-check numbers are in.** Build it only if built-in speakers miss the 2 dB threshold with V1 (check V1 in [MAC_DEMO_CHECKS.md](MAC_DEMO_CHECKS.md)), or if a later step drops voice processing on speakers. Nothing here exists in the code. No number below is a measurement; each one is a starting value or an estimate and is labelled as such.

## Where this fits
- **V1 (in this PR):** the mic keeps Apple voice processing, with other-audio ducking set to advanced off and level `.min` (macOS 14+). Apple says `.min` minimizes ducking; it is not zero. The mic, and with it voice processing and any Bluetooth hold, is released while Paused, while muted in the call app, and right after a "Use Zoom/Meet controls" call-end report. The 30 s `stop_after_s` tail stays only when no call signal exists for the session's app.
- **V3 (this note):** drop voice processing on the speakers route, so nothing ducks, and do the echo job ourselves against the call stream.

## Why the echo job exists
The mic stream counts as "the user speaking" when the WebRTC VAD says speech and the frame is at or above `min_rms_dbfs: -50`. There is no comparison of the mic against the call stream. With voice processing off on speakers, call audio leaking into the mic would read as the user talking. Every far-side sentence would then look like overlap, and false red interrupt and talk-over cues would fire. On headphones (wired or Bluetooth) there is no acoustic path, so nothing leaks.

The far side already arrives clean as its own stream: ScreenCaptureKit audio filtered to the call app, or a Core Audio process tap on Chromium helpers (`CallCapture`), resampled to 24 kHz mono. `FrameAligner` pairs mic and call frames (20 ms hop, up to 200 ms lag). That stream is the reference signal for an echo check.

## 1. Goal
Run the mic without voice processing, so there is no ducking at all, and still keep call audio that leaks from the speakers from counting as the user.

Not a goal: better audio for the user or the far side. The mic stream only feeds the coach (and, with a key, its transcription); nothing is played back.

## 2. Approach
Use the call stream as the reference. Work on each 20 ms frame pair from `FrameAligner`.

1. **Delay.** Estimate the speaker-to-mic delay once every few seconds. Cross-correlate the mic energy envelope (or band-limited samples) against the call stream over 0 to 300 ms. The delay is capture skew between the two capture APIs plus the acoustic path. Track it slowly: a new estimate moves the working delay only when it beats the old one for several rounds in a row.
2. **Leak estimate.** Start cheap: a single delay and gain, so the predicted leak is `g * call[t - d]`. Then, if that is not enough, a short adaptive filter (NLMS, a few hundred taps at 16 kHz, the rate the VAD already uses) that also covers early room reflections.
3. **Residual.** Subtract the predicted leak from the mic frame and measure what is left.
4. **Decision.** The mic counts as "the user speaking" only when all of these hold:
   - the residual passes the VAD;
   - the residual is at or above the existing `-50` dBFS gate;
   - the residual exceeds the predicted leak by a margin (6 dB as a starting value, to be tuned).
5. **Double-talk.** Freeze adaptation while the user is detected, so the filter doesn't learn the user's voice and cancel it.
6. **Silent call stream.** When the call stream is silent, no gating applies and the mic is judged as today.
7. **Route.** Only on the built-in speakers route. Headphone routes (wired or Bluetooth) skip the check.
8. **Where it runs.** On the engine queue, in front of the local layer, never on the audio thread. The mic tap stays as thin as it is now.

**CPU (an estimate, not a measurement).** The single delay and gain costs a few hundred operations per frame. An NLMS filter of 300 taps at 16 kHz is 320 samples per 20 ms frame, each with a 300-tap filter and a 300-tap update. That is about 200,000 multiply-adds per frame, or about 10 million per second at 50 frames per second. That is small next to the VAD and resampling already running, but it has to be shown by test (see 4e), not assumed.

## 3. Risks
**False cues (leak not fully removed):**
- Room reverb tails longer than the filter leave a residual that looks like speech.
- Nonlinear speaker distortion at high volume cannot be predicted by a linear filter.
- Laptop speaker-to-mic coupling changes when the lid angle changes.
- The delay jumps when the output device or sample rate changes.
- The call stream and what the speakers play differ, because the OS applies volume, EQ and spatial audio after capture. The gain estimate has to follow volume changes.

**Missed cues (the user is hidden by the check):**
- The user's real interruptions happen exactly while the far side talks. That is double-talk, the case the check is worst at.
- An over-aggressive margin hides real cut-ins and talk-overs, which are the coach's core cues.
- Quiet talkers sit close to the margin.
- Adaptation drift: a filter that keeps adapting through quiet double-talk slowly learns the user.

**Not covered:**
- The reference is captured per app. Other apps' sound (music, notifications) is not in the reference and leaks through as before. Music is mostly rejected by the VAD. Speech-like audio from another app (a video, a podcast) is not.

## 4. Tests that would prove it
All synthetic. No real-person audio goes in the repo; tests generate their audio the way `Synthetic.swift` does (`speechish`, `track`, `noise`). Every "stated budget" and "stated tolerance" below is set before the code is written and recorded in the test, not picked afterwards to fit.

- **a. Leak only.** Far-side synthetic speech convolved with a synthetic room impulse response (exponential decay, 100 to 400 ms RT60), at several gains (-40 to -15 dBFS at the mic) and delays (20 to 250 ms). Pass when the count of "user speaking" frames stays under a stated budget and no interrupt or talk-over cue fires.
- **b. Double-talk.** Synthetic user speech mixed over the leak. Pass when cut-in and talk-over cues still fire, with onset timing within a stated tolerance of the clean-mic baseline. Reuse the `LocalLayer` expectations for what a cue looks like on a clean mic.
- **c. Route change.** A delay jump mid-stream, and a gain change. Pass when the check recovers within a stated time and no burst of false cues appears while it does.
- **d. Silence and music-like noise as the reference.** A silent call stream means no gating. A noise-like reference must not produce a spurious delay lock or hide the user.
- **e. CPU.** A per-frame time budget measured on CI, run for a long clip, with the check on and off.
- **f. Property test.** Random gains and delays inside the ranges above. Pass when (a) and (b) hold for every draw.

**Mac hand check** (run only if V3 is built): built-in speakers, music plus a test call, count false cues per 10 minutes with V3 and with V1, and note the dB drop between Paused and Listening for V3.

## 5. Inputs needed before building
- The V1 hand-check numbers on built-in speakers: the dB drop between Paused and Listening.
- Whether V1 misses the 2 dB threshold on speakers.

If V1 passes on speakers, V3 stays a note.

## 6. Model tier
If this is built, the DSP and the engine-queue code are Opus work: the delay tracking, the adaptive filter, the double-talk freeze and the thread boundaries. The synthetic tests and the docs can be done at a lower tier.
