# How the coach works

The listen-more coach watches the shape of your conversation during a call and gives you a quiet visual nudge when you start to dominate it. It never plays a sound, and it keeps nothing after the call ends.

## Who is talking

The coach listens to two separate audio streams. Your microphone is "you", and the call app's output is "everyone else". Because the streams are separate, the coach knows who is speaking without any voice recognition. Captions and saved transcripts use the same split: lines are labelled **You** (mic) and **Them** (call audio). "Them" is not split further into individual speakers (see [Speakers](#speakers)).

## Two layers of detection

**Local layer (on your Mac, under 0.5 s).** Voice activity detection (the WebRTC detector) runs on each stream. From that it tracks:

- **Interrupt:** you start while someone else is talking and keep going: at least 0.6 s of overlap, with them still talking for 0.5 s and you past a short "mm-hm". Starting as they finish only counts if their last words were unfinished ("and", "but", "so" …).
- **Talk-over:** three or more back-and-forth switches within 4 s, with real overlap, ending with you holding the floor.
- **Monologue:** a soft nudge after 60 s of you talking without a break (earlier if that is well past your usual turn length in this call, never under 30 s) and a stronger one at 90 s.
- **Talk share:** you hold more than 65% of the talk time over the last 10 minutes (70% in a one-on-one), once there is at least 5 minutes of speech.
- **Tone flags:** your loudness and speaking rate, compared with your own baseline from earlier in the same call.

**Transcript rules (on your Mac).** OpenAI transcribes speech live, and simple rules run on the transcript in memory: a question to you that your reply drifts away from, and heated phrasing (absolutes, frustration, repeating yourself; word choice alone also needs a rise in your tone). Heat is never flagged in the first 5 minutes or right after an apology.

**GPT layer (under about 3 s).** A judge model reads the recent turns plus the local tone flags and returns at most one cue (aggressive, missed question, not listening, or occasionally an interruption the local layer missed) with a confidence score and a short reason. Requests use `store: false`, and each call has a budget cap (default $1).

**Ask-back cue (self-pivot).** When someone shares something personal (news, a worry, an event in their life) and you answer at length with your own story without asking anything back, a local gate on your Mac (`PivotGate`) marks the moment as a candidate. Acknowledging first ("congrats", "so sorry") and then telling your own story still counts; offering help, passing on a message for them, planning something for them or the group, or asking them a question doesn't. Only a candidate is judged, by the judge you set up and on its own lane: the two turns (theirs, then yours), redacted, go to it with `store: false`, and it answers self_pivot or none. A self_pivot answer at confidence 0.85 or higher, within 10 s of the end of your reply, becomes an amber "Ask about them" nudge, through the same cooldowns as every other cue. At most 20 such judge calls and $0.02 per call (`gpt.self_pivot_*`), and none within 180 s of the last candidate; these hold for the whole call, across Pause and the call app's mute. Each candidate gets one judge request and it is never sent again, whatever the reply or how late it comes; every request sent counts against the cap. Reaching a cap or a judge error stops only this cue for the rest of the call. In MeetingCard it is on by default inside the coach when a key is present, but nothing is sent or shown until its one-time notice has been answered. The notice opens at the next coach enable or call start (while a call is starting, before the coach is listening), never during a live call; one still up when a call goes live comes down and opens again at the next of those moments. Settings → Remind me to ask back turns the cue off at once, and Show Notice Again opens the notice on request. Only the OpenAI GPT judge can check it today: with TypeSafe selected it is off (Settings says so), and it never falls back to another provider. On a group call everyone else is one stream, so what others said can be part of the two turns. The judge's calls and spend are counted apart from the other cues' in the per-call meter and the harness cost log.

**Cue judge.** Settings picks who judges your reply (`judge.provider`). **OpenAI GPT** is the default and works as described above. **TypeSafe System One** asks a TypeSafe endpoint one fire / no-fire question per judged cue (aggressive, not listening, missed question). It sees only a minimal window: at most 8 transcript lines from the last 30 s, each labelled ME or OTHERS with how many seconds ago it was heard, and with links, email addresses, runs of five or more digits and your configured names redacted. No audio, tone flags or prompt go to it. A fire answer below confidence 0.7, an error or no answer within 6 s gives no cue. Three failed calls in a row stop judging for that call, while transcription and the transcript rules keep running. The transcript rules still raise heat and missed questions themselves; the cooldowns keep it to one glow. Settings then says why judging stopped (for example the key wasn't accepted, or TypeSafe didn't answer in time). Each call's latency and the `usage` tokens TypeSafe reports are recorded (TypeSafe reports cost as tokens per call-hour, with no dollar rate), and a per-call price (`cost_usd_per_call`, unset by default) counts toward the budget cap only when you configure one. Transcription stays with OpenAI.

## The cue

A cue is a glow at the edge of your screen:

- **Red:** interrupt, talk-over, or aggression.
- **Amber:** not listening, a missed question, a monologue, high talk share, or the ask-back cue.

A cue from the judge model only fires when its confidence is 0.7 or higher. In MeetingCard, not listening nudges are off by default, and while they are off the judge isn't called at all. Each cue also tints the coach card (or its pill) amber or rose for 4.5 s with a few words saying what it was, so color is never the only cue, and VoiceOver reads it. The glow plays once over about 3 s: a quick rise, a short hold, then a slow fade (with Reduce Motion on, it appears and fades over 2 s). It shows on the display with the call app's window. Each cue type has a 20 s cooldown, so you won't see the same nudge twice in a row. After any nudge, the others wait 20 s too, with one exception: right after a judged nudge, an interrupt nudge waits only for its own cooldown. One nudge shows at a time, and a new one never replaces the nudge on screen: one that comes during those 4.5 s is dropped. The coach's 4.5 s runs on the audio engine's clock, while the card's 4.5 s starts when the nudge arrives on the main thread (`CoachController.showNudge`, system uptime), so delivery jitter could let the next nudge replace one in its last few tens of milliseconds.

## Starting and stopping

The coach starts on its own when an allowlisted call app (or any app, if you turn that on in Settings) has both the microphone and speakers active for about 3 s. It stops about 30 s after either one goes off, or, for a meeting you joined from a MeetingCard card, when that calendar event ends.

Core Audio is the fallback signal, and it lags: a call app can keep the mic and speakers open after you leave. The trigger therefore accepts an optional app-level call-state signal (`CallStateProvider`: started, ended or muted per app). When that signal reports a call ended, the coach releases the microphone right away, stops about 3 s later (`ended_stop_after_s`) and doesn't restart for that app while its audio stays open. While it reports the session's app muted, the coach holds capture the same way Pause does (no capture, no streams) and resumes on unmute; your own Pause stays in place until you resume. Started and muted never start or hold a session.

The coach menu has its own **Mute My Mic for Coach**, separate from the card's **Mute in Zoom** control and from Zoom's own mute. It stops the coach's mic engine (the input device is released and voice processing is off), so no mic audio goes to OpenAI and no You text is produced, while call audio, Them captions and the cues about the other side carry on; the card reads "Coach is hearing others only" and the chip "Coach can't hear you". A line you were still saying, or had just finished, when you pressed Mute is dropped rather than transcribed (the transcriber is told to clear it). If OpenAI refuses that clear, nothing stops: the other side keeps streaming and being captioned, the refusal is logged by its event type only (no audio, no text), and the clear is sent again at Unmute before any new mic audio. The cues that read your speech can't fire from the gap or because of it:
- **Interrupt** (cut-in) and **talk-over**: nothing to detect while muted; a pending cut-in and the speaker-switch log are dropped at Mute and Unmute, and for `local.unmute_grace_s` (1 s) after Unmute your speech opens no cut-in and counts as no switch, while the echo canceller restarts with the mic.
- **Monologue**: your turn in progress is dropped (no shortened run enters your usual run length); a new turn starts after Unmute.
- **Missed question**: a pending question is dropped at Mute and Unmute, and questions asked while you're muted don't open one.
- **Not listening** (off by default in MeetingCard) and the TypeSafe judge: the "they spoke, now you reply" trigger starts over at Mute and Unmute, so your first line back isn't judged as a reply to the gap.
- **Talk share** keeps counting, with you silent (what the call heard), so the gap can only lower your share. **Heat** has none of your text to read while muted.

It lasts until **Unmute My Mic for Coach** or until the session ends (the next call starts unmuted), and it survives Pause and Zoom's own mute, so resuming keeps the mic off. It never touches the call app: no Accessibility, no Automation, no new permission.

MeetingCard's provider is the **Use Zoom/Meet controls** setting (off by default). Without it, or for any app whose permission is missing, revoked or unsupported, the 30 s Core Audio stop applies.

- **Zoom** (Accessibility): in a meeting while Zoom's menu bar has its in-meeting shortcuts (⇧⌘A mute/unmute audio, ⇧⌘V start/stop video). Leaving (or closing the meeting window, or quitting Zoom) removes them, which reads as ended. Muted while the ⇧⌘A item offers Unmute. That item's label is the only text read, and it's reduced to muted or not on the spot. Zoom in another language: start and end work, and mute stays unknown (the coach keeps listening while muted). The coach card's **Mute in Zoom** control (`CallControlsModel.toggleMute()`) presses that same ⇧⌘A item once through Accessibility (no synthesized keys or events) and reads Zoom's mute state back right after. It shows only while it can act: Use Zoom/Meet controls on, Accessibility granted and Zoom in a meeting. Otherwise (`toggleOff`, `permissionDenied`, `noZoomCall`, `meet`) it's hidden, and the pill keeps the coach's own Mute, Pause and Stop.
- **Meet in Chrome and Dia** (Automation, AppleScript): in a call while any tab is a `meet.google.com` meeting (`/abc-defg-hij`). The browser itself narrows its tabs to the Meet host (`whose URL starts with`), the script checks the meeting path and returns only a count, so no title and no other URL leaves the browser. **Meet mute is not detected**: Meet's mute state isn't readable without page content, so it's never reported, and muting in Meet (Chrome or Dia) doesn't pause the coach. Only Zoom's mute does. There is no mute action for Meet either (`canMute` is false with reason `meet`: mute from Meet), and that control never "mutes" by stopping the coach's own audio capture. Dia lists a window's tabs per space, so its script walks every space. Dia added AppleScript in 1.7.0. On a Dia that can't list tab URLs this way (an older Dia, or one without `whose` on tabs), Dia falls back to Core Audio.

An ended call is reported for up to `stop_after_s` (30 s) after it ends; after that Core Audio decides again.

On headphones, wired or Bluetooth, the coach uses no voice processing, so nothing is lowered. With Bluetooth output it always uses the Mac's built-in mic, so AirPods never switch to the hands-free profile; a Mac with no built-in mic then runs on call audio only, and shows a one-time notice on the coach card and a note in Settings that mic cues are off while Bluetooth headphones are used. The coach never opens a Bluetooth input. With the lid closed, if the built-in mic delivers no audio, or only digital silence, for 3 s, the coach sets it aside and runs on call audio only instead of capturing silence; it tries the mic again when the audio routes really change or on the next call. On speakers it uses Apple's voice processing, so call audio isn't mistaken for you, and sets the lowering of other audio to Apple's minimum. Pause, the coach's Mute and, with **Use Zoom/Meet controls**, being muted in Zoom or leaving the call release the mic at once (without it, leaving the call releases it at the 30 s stop), and a change of output or input reopens it on the new route.

## Without an API key

The coach turns on without a key. It then runs the local layer only (interruptions, talk-over, monologue and talk share), and nothing is sent anywhere. The transcript rules and the GPT layer need the transcription and judge calls, so they stay off until a key OpenAI accepts is saved. A saved key that OpenAI rejects is flagged in Settings and the coach menu, and the coach keeps running local-only.

## Live captions and saved transcripts (opt-in)

Both are off by default, in Settings under **Captions and transcript**, and both need a key OpenAI accepts: they show the text of the same live transcription the GPT cues already use, so they add no API calls and no cost. The first time either one is turned on, a notice explains that the other people on the call are being transcribed and that you are responsible for telling them and for following the law and any policies that apply to you. "Not Now" leaves the feature off.

- **Live captions.** Shown in the coach card's captions area during a call (the reminder card turns into the coach card); captions have no window of their own. The card hosts `CaptionFeedView` in its compact card layout: up to three of the newest lines as they are transcribed, each labelled with its speaker; consecutive turns by the same speaker within 4 s share a line, and long lines keep their newest words. Captions are in memory only (at most three lines) and are dropped when the call ends.
- **Saved transcripts.** One Markdown file per call, `Call <date> <time>.md`, in `~/Library/Application Support/MeetingCard/Transcripts` unless you choose another folder (a `build.sh --test-id` build uses `MeetingCard-Test/Transcripts` and keeps its own settings, so it never shares transcripts or the Save transcripts setting with the real app). Each finished line has its time since the call started and its speaker label. While a file is being written, a "Saving transcript" badge shows on the coach card's status line (even with captions off, and under a nudge), in Settings, and in the coach menu; with saving off the card shows nothing about it. Settings and the coach menu can delete the current or last transcript; deleting during a call stops saving for the rest of it. The file is readable by your user only (mode 600).
- **Speaker names.** During a call you can rename "You" or "Them" in Settings. Names last for that call only; they are kept only inside that call's saved transcript, if saving is on.
- **Cost cap.** When a call reaches its cost cap, the transcription stops: captions show that they stopped, the transcript file is finished, and the on-device cues continue. The Settings cost line shows the call's spend so far, with captions and transcript at $0.00 extra.

### Speakers

Only "You" and "Them" are labelled. OpenAI's live transcription model (`gpt-live-transcribe`) returns no speaker labels. Its one diarizing model, `gpt-4o-transcribe-diarize`, works only on uploaded files (`POST /v1/audio/transcriptions`, 25 MB per request, about $0.006 per minute), not on live streams, and it is deprecated with a shutdown date of February 26, 2027. Telling "Them" apart would mean holding call audio in memory, uploading it in chunks for a second paid transcription, and matching speakers across chunks, with labels arriving minutes late, on a model that is about to be retired. MeetingCard doesn't do that.

## Privacy

Audio stays in memory in every mode and is never written to disk. With saving off (the default) nothing is written to disk at all: captions and transcript text stay in memory and are gone when the call ends. With saving on, the only write is that call's one transcript file in the folder you chose. No stats are kept, and logs contain no call content, transcript text or keys.

```mermaid
flowchart LR
    Mic["Mic (you)"] --> VAD["Local layer<br/>voice activity, overlap,<br/>talk share, tone (&lt;0.5 s)"]
    App["Call app output<br/>(everyone else)"] --> VAD
    Mic --> STT["OpenAI live transcription"]
    App --> STT
    STT --> Judge["Judge: OpenAI GPT (default)<br/>or TypeSafe System One<br/>cue + confidence (&lt;3 s)"]
    VAD -->|tone flags| Judge
    VAD -->|interrupt, talk-over,<br/>monologue, talk share| Glow["Screen-edge glow<br/>red or amber, 20 s cooldown"]
    Judge -->|confidence ≥ 0.7| Glow
    VAD -->|self-pivot candidate<br/>(two turns, redacted)| SP["Self-pivot judge<br/>configured provider only,<br/>store false, ≤ 20 calls / $0.02"]
    SP -->|confidence ≥ 0.85| Glow
    STT -.->|opt-in| Captions["Captions in the card<br/>You / Them, memory only"]
    STT -.->|opt-in| File["Transcript file<br/>one .md per call"]
```
