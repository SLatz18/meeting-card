import Foundation

/// The built-in coach config. It lives in source (not a bundle resource) so the app, `swift test`
/// and xcodebuild all read the same bytes without resource-bundle plumbing. No secrets here: the
/// OpenAI key is entered in MeetingCard's Settings and stored only in the Keychain.
/// Override for tuning with a JSON file (deep-merged): `ListenMoreConfig.load(overrideURL:)`.
public enum DefaultConfig {
    public static let json = #"""
{
  "audio": {"sample_rate": 24000, "frame_ms": 20},
  "vad": {"onset_frames": 2, "onset_window": 3, "hangover_ms": 200, "min_rms_dbfs": -50,
          "voicing_threshold": 0.45, "voicing_min_hz": 80, "voicing_max_hz": 400},
  "local": {
    "interrupt_confirm_ms": 300,
    "interrupt_others_min_active_ms": 300,
    "talk_over_ms": 1000,
    "monologue_s": 75,
    "monologue_others_floor_ms": 1000,
    "monologue_me_gap_reset_s": 2.5,
    "talk_share_window_s": 300,
    "talk_share_max": 0.55,
    "talk_share_min_speech_s": 120,
    "prosody_baseline_min_s": 6.0,
    "prosody_baseline_max_s": 30.0,
    "prosody_loudness_jump_db": 5.0,
    "prosody_rate_jump_pct": 25.0
  },
  "cues": {
    "cooldown_s": 20,
    "fade_s": 3,
    "gpt_min_confidence": 0.7,
    "colors": {
      "interrupt": "red", "talk_over": "red", "aggressive": "red",
      "not_listening": "amber", "missed_question": "amber",
      "monologue": "amber", "talk_share": "amber"
    }
  },
  "gpt": {
    "realtime_url": "wss://api.openai.com/v1/realtime?intent=transcription",
    "transcribe_model": "gpt-live-transcribe",
    "transcribe_delay": "low",
    "transcribe_preroll_ms": 300,
    "responses_url": "https://api.openai.com/v1/responses",
    "judge_model": "gpt-6-luna",
    "judge_reasoning_effort": "none",
    "judge_window_s": 90,
    "judge_min_interval_s": 1.5,
    "judge_timeout_s": 6,
    "question_wait_s": 4.0,
    "store": false,
    "prices_usd": {
      "transcribe_per_minute": 0.017,
      "judge_input_per_mtok": 0.10,
      "judge_cached_input_per_mtok": 0.01,
      "judge_output_per_mtok": 0.50
    },
    "budget_usd_per_call": 1.00
  },
  "trigger": {
    "poll_s": 0.5,
    "start_after_s": 3,
    "stop_after_s": 30,
    "exclude_bundle_ids": ["com.slatz.meetingcard.swift", "com.listenmore.mac"]
  },
  "capture_targets": [
    {"name": "Zoom", "kind": "zoom", "process_name": "zoom.us", "bundle_id": "us.zoom.xos",
     "bundle_id_status": "widely documented; confirm with: osascript -e 'id of app \"zoom.us\"'"},
    {"name": "Google Chrome", "kind": "browser", "process_name": "Google Chrome", "bundle_id": "com.google.Chrome",
     "bundle_id_status": "documented; helper audio reports com.google.Chrome.helper*"},
    {"name": "Dia", "kind": "browser", "process_name": "Dia", "bundle_id": "company.thebrowser.dia",
     "bundle_id_status": "UNVERIFIED. Third-party sources agree (Installomator metadata dia.plist, installomatortracker.org). Confirm with: osascript -e 'id of app \"Dia\"'. Helper bundle IDs unknown."},
    {"name": "Microsoft Teams", "kind": "app", "process_name": "Microsoft Teams", "bundle_id": "com.microsoft.teams2",
     "bundle_id_status": "new Teams; confirm with: osascript -e 'id of app \"Microsoft Teams\"'"},
    {"name": "Microsoft Teams (classic)", "kind": "app", "process_name": "Microsoft Teams classic", "bundle_id": "com.microsoft.teams",
     "bundle_id_status": "classic Teams; confirm on a Mac"},
    {"name": "Webex", "kind": "app", "process_name": "Webex", "bundle_id": "Cisco-Systems.Spark",
     "bundle_id_status": "Webex app; confirm with: osascript -e 'id of app \"Webex\"'"},
    {"name": "Webex Meetings", "kind": "app", "process_name": "Cisco Webex Meetings", "bundle_id": "com.cisco.webexmeetingsapp",
     "bundle_id_status": "Webex Meetings app; confirm on a Mac"},
    {"name": "FaceTime", "kind": "app", "process_name": "FaceTime", "bundle_id": "com.apple.FaceTime",
     "bundle_id_status": "UNVERIFIED as an audio client: call audio may run in a system daemon, not the app. Check on a Mac."},
    {"name": "Slack", "kind": "app", "process_name": "Slack", "bundle_id": "com.tinyspeck.slackmacgap",
     "bundle_id_status": "huddles; Electron helpers report com.tinyspeck.slackmacgap.helper*. Confirm on a Mac."}
  ]
}
"""#
}
