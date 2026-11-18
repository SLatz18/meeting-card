# Transcripts as Obsidian notes

With **Save transcripts** on, MeetingCard writes one Markdown note per call, from the call's start to its
end, into a folder you choose. If that folder is in an [Obsidian](https://obsidian.md) vault, the note is
ready to use there: properties, tags, cue links and an optional link from the daily note. MeetingCard
writes plain files only. It needs no Obsidian plugin, no `obsidian://` link and no running app, so it works
with Obsidian closed (or not installed).

Saving is still opt-in and off by default. It needs a key OpenAI accepts, because it reads the transcription
the GPT cues already run, so it adds no API calls. The first time captions or saving is turned on, the
existing generic notice explains that the other people on the call are transcribed. **No audio is ever
saved**, and nothing is sent anywhere (no telemetry).

All copy shown below is placeholder text pending copy review.

## Settings

In Settings, under **Captions and transcript**:

| Setting | Default | What it does |
|---|---|---|
| Save transcripts | Off | Saves one note per call |
| Save transcripts to | `~/Library/Application Support/MeetingCard/Transcripts` (test build: `MeetingCard-Test/Transcripts`) | Any folder. If it or a parent has an `.obsidian/` folder, Settings shows the vault's name |
| File name | `{date} {time} {title}` | Also `{app}`. See [File names](#file-names) |
| Tags | `meeting/transcript` | Separated by commas; a leading `#` is dropped, spaces become `-` |
| Link from the daily note | Off | Appends one line to the day's note. See [Daily note](#daily-note) |
| Daily note path | `Daily/{yyyy}-{MM}-{dd}.md` | Under the vault, or under the chosen folder when it isn't in a vault. Also `{date}` |
| Show the call as | Link | **Link**: `- 09:05 [[path\|title]]`. **Embed**: `![[path]]` (Obsidian shows the note inside the daily note; its text stays in the call's file) |
| Keep transcripts | Forever | Or 7, 30 or 90 days, or 1 year. See [Delete and retention](#delete-and-retention) |
| Delete This Call's Transcript | | Removes the current call's notes (or the last call's) |

The folder is kept as a bookmark plus its path. It is looked up again at each call's start and whenever it
is no longer where it was, so a rename or a move is followed rather than the old path recreated. A chosen
folder that is missing or in the Trash takes no notes: Settings says so under the path, nothing is saved, and
nothing goes anywhere else instead. MeetingCard isn't sandboxed, so this needs no entitlement. A sandboxed build would make the bookmark security-scoped and would need
`com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`.

## File names

The pattern fills `{date}` (`2026-01-31`), `{time}` (`0905`, the call's local start), `{title}` and `{app}`.
The title is the calendar event's, when the call was joined from a reminder card and is still within that
event, and **Call** otherwise. The name is then made safe for macOS, Windows, Android and Obsidian links:

- `/ \ : * ? " < > | # ^ [ ] %` and control characters become spaces, runs of spaces become one, and runs
  of dots become one (a name never holds `..`);
- leading and trailing dots and spaces are removed (a leading dot would hide the file);
- names are cut to 120 characters and to 200 UTF-8 bytes, so a long title in any script still leaves room
  for ` (n)`, `.md` and the hidden temporary file beside it within the usual 255-byte limit;
- a Windows device name (`CON`, `NUL`, `COM1`…, the part before the first dot) gets an `_` there: `con.txt`
  becomes `con_.txt`;
- a pattern that leaves nothing falls back to the default.

If the name is taken (compared without case), the note gets ` (2)`, ` (3)` and so on. The note's first
write never replaces a file: if something appears at the name between choosing it and writing (another
app, a sync), the note moves on to the next free name.

## What a note holds

Properties (YAML front matter):

| Property | Example | Notes |
|---|---|---|
| `date` | `2026-01-31` | The call's local date |
| `start`, `end` | `2026-01-31T09:05:07` | Local time; `end` is written when the call ends |
| `duration` | `"00:02:41"` | Written when the call ends |
| `meeting-app` | `"Zoom"` | The call app, when known |
| `title` | `"Synthetic planning call"` | When known |
| `participants` | | Only when known. MeetingCard doesn't read attendee names today, so it is left out |
| `speakers` | `You`, `Them` | The labels used, including names typed in Settings during the call |
| `tags` | `meeting/transcript` | From Settings |
| `transcriber` | `"gpt-live-transcribe"` | The transcription model |
| `coach-cues` | `2` | Coaching cues shown during the call |
| `transcript-status` | `complete` | `in-progress` during the call, `recovered` after a crash |
| `recovered` | `2026-01-31T10:12:00` | Only on a note recovery wrote: when it did (local time) |
| `meetingcard-call` | `"c0123…"` | A random ID. Retention and the daily-note line use it to recognise MeetingCard's own notes |
| `meetingcard-saved` | `1769850468` | On a finished note: MeetingCard's last write (the call's end, or when recovery wrote it) in seconds since 1970, the same instant in every time zone. Retention reads only this |

Then the body:

1. **Summary**: a fixed placeholder for your own summary. MeetingCard never writes one.
2. **Coaching cues**: each cue's time links to the transcript line it fell in, through that line's block ID
   (`[[#^l4|00:00:18]]`), so clicking it jumps to the line.
3. **Transcript**: one paragraph per turn, `**[time since the start] Speaker:** text ^l<n>`, at the time the
   turn started. Text is escaped so it can never turn into tags, links, embeds, comments, math or HTML.

Gaps are marked where they happen, with their start and end:

| Gap | Shown as |
|---|---|
| The coach's own Mute (Mute My Mic for Coach) | `*[start–end] Coach mic off: no You text.*` (Them is still transcribed) |
| Pause | `*[start–end] Coach paused: nothing transcribed.*` |
| Muted in the call app (with Use Zoom/Meet controls) | `*[start–end] Muted in the call app: nothing transcribed.*` |
| Transcription stopped (cost cap or error) | `*[start–end] Transcription stopped (cost cap reached).*` |
| Transcriber retrying, call audio reconnecting | `*[start–end] Transcription reconnecting.*`, `*[start–end] Call audio reconnecting.*`. The format has them, but MeetingCard doesn't report either yet; see [Limits](#limits) |
| The app quit mid-call (recovered) | `*[time–] The app quit during the call; this transcript was recovered and ends here.*` |

## Sample note

Synthetic content only: no real people, meetings or companies. The same file is
[`docs/samples/2026-01-31 0905 Synthetic planning call.md`](samples/2026-01-31%200905%20Synthetic%20planning%20call.md),
and `SampleNoteDocTests` checks that both match what the code writes.

```markdown
---
date: 2026-01-31
start: 2026-01-31T09:05:07
end: 2026-01-31T09:07:48
duration: "00:02:41"
meeting-app: "Zoom"
title: "Synthetic planning call"
speakers:
  - "Them"
  - "You"
tags:
  - "meeting/transcript"
transcriber: "gpt-live-transcribe"
coach-cues: 2
transcript-status: complete
meetingcard-call: "c0123456789abcdef"
meetingcard-saved: 1769850468
---

## Summary

_Summary placeholder: add yours after the call._

## Coaching cues

- [[#^l4|00:00:18]] Interruption
- [[#^l7|00:02:12]] Missed question

## Transcript

**[00:00:04] Them:** Thanks for joining. Shall we start with the release timeline? ^l1

**[00:00:09] You:** Yes. The first draft is ready for review. ^l2

**[00:00:15] Them:** Great. What is the biggest open risk? ^l3

**[00:00:17] You:** Before you go on, I think it is the test plan. ^l4

*[00:00:30–00:00:52] Coach mic off: no You text.*

**[00:00:35] Them:** Then let's give the test plan another week. ^l5

*[00:01:05–00:01:40] Coach paused: nothing transcribed.*

**[00:02:05] Them:** Does Friday work for the review? ^l6

**[00:02:09] You:** The draft also needs new screenshots. ^l7

**[00:02:30] Them:** Okay. Talk soon. ^l8
```

## Daily note

With **Link from the daily note** on, the call adds one line at the end of the day's note. The note is found
from the path pattern, under the vault (or under the chosen folder when it isn't in a vault):

```markdown
- 09:05 [[Meetings/2026-01-31 0905 Synthetic planning call|Synthetic planning call]] %%meetingcard:c0123456789abcdef%%
```

- **Append only.** Nothing already in the daily note is changed. If it doesn't end with a newline, the line
  starts on a new one.
- **Idempotent.** The hidden `%%meetingcard:<id>%%` marker means the same call never adds a second line,
  including after a crash and recovery.
- **Created if missing**, with its folders, holding just that line. If you use Obsidian's Daily notes
  template, open the day's note in Obsidian before your first call so the template is applied first.
- A path pattern that is absolute, starts with `~`, uses `..` or goes through a symlink out of the vault is
  refused (no line is written). Recovery checks the path again, and makes the line again, rather than
  trusting what the spool says.
- The line is added when the call starts, so even a call the app quits during is linked.

## While a call is saving

- Each finished line, gap, cue and speaker name is appended to the call's spool,
  `.meetingcard-<id>.spool`, and synced to disk (F_FULLFSYNC on macOS). The spool is a hidden file in the
  chosen folder; Obsidian and Finder don't show dot files.
- Then the whole note is replaced atomically: written to a hidden temporary file beside it, synced, and
  renamed over the note. Obsidian, or anything else reading it, sees the old version or the new one, never
  half of one. Writes never follow a symlink.
- All of this runs on a background queue, in order, off the main thread, including choosing the name and
  finding the vault when the call starts.
- **Editing the note during the call is safe.** If the note on disk is no longer what MeetingCard last
  wrote, or can't be read, it is never overwritten: the rest of the call goes to a new note beside it
  (` (2)`).
- **Deleting the note during the call** (in Finder or Obsidian) stops saving for that call; it isn't recreated.
- When the call ends, the note gets its end time and duration, and the spool is removed.
- Quitting MeetingCard during a call finishes the note at the time of the quit. Quit waits at most 2 s for
  the writes; anything still queued is recovered at the next launch.

## If the app quits mid-call

If MeetingCard crashes, is force-quit or loses power during a call, the spool is still there. At the next
launch, and after every call, MeetingCard rebuilds the note from the spool, including lines that hadn't reached the note yet,
ends it at the last thing recorded with the app-quit line, sets `transcript-status: recovered`, and removes
the spool. A torn last line in the spool (from a crash mid-write) is skipped. If you edited the note after the
crash, the recovered note goes beside it instead. Recovery also clears temporary files more than an hour old.

Recovery trusts nothing in a spool, which may have come from another Mac through a synced folder:

- it uses a note name only if it is a single plain `.md` file name (no folders, no `..`, not hidden), so it
  writes only in the chosen folder;
- it finds the daily note again from its path relative to the vault, with the same escape checks;
- it leaves a spool that MeetingCard is still writing: on this Mac, only if the same process (the same boot,
  PID and process start time) is still running, so a crash before a reboot or a reused PID is recovered; on
  another Mac sharing the folder, until the spool has been untouched for six hours. Each spool names its
  machine by a hash of the hardware UUID (`/etc/machine-id` on Linux), never the Mac's name or the UUID itself.
  If either the spool or this Mac has no such ID, a spool from another boot could be another Mac's, so it
  also waits until it has been untouched for six hours;
- it never writes over a file it didn't write: a note changed after the crash gets the recovered note beside it.
  The one exception is an empty note a crash left while claiming its name on a FAT or exFAT volume, which it
  fills in.

So a note can stay `in-progress` for a while: another Mac's call still under six hours old, or one another
MeetingCard on this Mac is writing. Settings then says how many transcripts are unfinished, under the folder,
and upkeep tries again after the next call and at the next launch.

## Delete and retention

- **Delete This Call's Transcript** (Settings or the coach menu) removes the current call's note, including a
  note started beside it after an edit, and its spool. It does the same for the last call's, once that call
  has ended. During a call, saving stops for the rest of it. The daily note keeps its line (append only), so
  its link then shows as unresolved in Obsidian.
- **Keep transcripts** (off by default, so notes are kept forever) removes notes after each call, at launch
  and when the setting changes. It only removes notes that:
  - carry `meetingcard-call`;
  - sit directly in the chosen folder (not in subfolders);
  - have a name the File name pattern could make;
  - have `meetingcard-saved` (so they aren't still `in-progress`) more than that many days ago;
  - haven't changed since that write, by more than 10 seconds.

  It reads only the first 4 KB of a note (its properties). `meetingcard-saved` is a time-zone-free instant,
  so travelling, or two Macs in different zones sharing a vault, doesn't change the answer. Your own notes,
  and notes you edited after the call (a summary added the same day, for example), are never removed. Notes
  made under an older File name pattern are kept too.

  Retention trusts the file's modified time. A sync tool that sets it to when it downloaded the file makes
  that copy look edited, so it's kept (safe). A network volume whose clock runs behind this Mac's can make
  an edit look up to that much older: an edit made within that skew of MeetingCard's last write can then be
  taken for no edit and the note removed. A clock that runs ahead is safe.

## Privacy

- Opt-in, off by default, behind the generic one-time notice. Audio is never written anywhere.
- Text goes only to the chosen folder: the note, its spool during the call, and temporary files beside the
  note while it's replaced. The one exception is the optional daily-note line (a link with the call's time
  and title), which goes in the daily note inside the same vault.
- Nothing is logged or sent: no telemetry, and no network code in the feature (checked by
  `TranscriptWiringTests` and `PrivacyGuardTests`).
- Files are readable by you only (mode 600).

## Limits

- **Them 1 / Them 2.** The note format supports numbered voices within Them, but the live transcription
  can't tell voices apart today, so every other person is **Them**. See [how-it-works.md](how-it-works.md#speakers).
- **Transcriber retries and call audio reconnects.** The transcriber doesn't retry or reconnect within a
  call today: an error stops transcription for the rest of the call, which is marked as a gap. MeetingCard
  doesn't report call audio reconnecting either (the capture fallback restarts at once). The note format has
  both gap kinds, ready for when it does.
- **Renaming the note during a call** counts as deleting it: saving stops for that call.
- **Renaming or moving the folder during a call** stops saving for the rest of that call: the call keeps
  writing to the old path, finds its note gone, and stops. The spool goes with the folder and is recovered
  later, but lines after the rename are lost. The next call follows the folder to its new place.
- **Participants** are left out because MeetingCard doesn't read attendee names.

## Tests

- Unit tests (ListenMoreCore, which also runs on Linux in the `Core on Linux` workflow):
  - `CallNoteTests`, `NoteFileNameTests`: properties, sanitizing, collisions;
  - `GapMarkingTests`: Mute, Pause and other gaps;
  - `TranscriptDurabilityTests`: incremental, atomic and exclusive writes, crash recovery (including spool
    paths that try to escape, live spools, unreadable notes), retention (including a note edited the day of
    its call), daily-note idempotence, path escapes, long non-Latin titles;
  - `TranscriptRecorderTests`: edited and deleted notes;
  - `PrivacyGuardTests`;
  - `SampleNoteDocTests`.
- Settings: `TranscriptSettingsSnapshotTests` (text snapshots of the rows) and the CI `snapshots` job
  (`packet-transcript-settings*-{light,dark}.png`).
- On a Mac: the OB rows in [MAC_DEMO_CHECKS.md](MAC_DEMO_CHECKS.md#transcripts-as-obsidian-notes-ob1ob7).
