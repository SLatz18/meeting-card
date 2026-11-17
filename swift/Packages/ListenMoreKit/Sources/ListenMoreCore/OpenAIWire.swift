import Foundation

/// Request bodies and response parsing for the two OpenAI endpoints (checked against
/// platform.openai.com docs, see the Kit README). Pure functions so they are testable without a
/// network; the transports live in ListenMoreMac.
public enum OpenAIWire {
    public static let judgeLabels = ["none", "interrupting", "aggressive", "not_listening", "missed_question"]

    public static var judgeSchema: [String: Any] {
        ["type": "object",
         "additionalProperties": false,
         "properties": ["cue": ["type": "string", "enum": judgeLabels],
                        "confidence": ["type": "number"],
                        "short_reason": ["type": "string"]],
         "required": ["cue", "confidence", "short_reason"]]
    }

    public static let judgeInstructions = """
    You are a silent, conservative listening coach for ME on a live work call.
    You see the last ~90 seconds of a speaker-labelled transcript (ME = the user's mic, OTHERS = everyone
    else on the call), plus local acoustic flags. Decide if ME needs a nudge RIGHT NOW about the most recent turns.
    Labels:
    - aggressive: ME's latest words are hostile, belittling, accusatory or contemptuous (e.g. insults,
      "that's ridiculous", "you never listen"), especially if the prosody flag shows a loudness/rate jump.
      Firm disagreement stated respectfully ("I disagree, we need to hold the date") is NOT aggressive.
    - missed_question: OTHERS asked ME a direct question and ME has not answered it (silence, or a
      change of subject). Only use when the question is clearly unanswered.
    - not_listening: ME's reply ignores or contradicts what OTHERS just said, repeats itself over their
      point, or dismisses it without engaging.
    - interrupting: ME cut someone off mid-thought (local detectors usually catch this; use rarely).
    - none: anything else. Prefer none when unsure. False alarms are worse than misses.
    Return confidence in [0,1] and a short_reason of at most 12 words.
    """

    /// Realtime transcription session: client-committed turns (no server VAD), 24 kHz PCM.
    public static func sessionUpdate(_ g: ListenMoreConfig.Gpt, sampleRate: Int) -> Data {
        var transcription: [String: Any] = ["model": g.transcribeModel]
        if let d = g.transcribeDelay { transcription["delay"] = d }
        let input: [String: Any] = ["format": ["type": "audio/pcm", "rate": sampleRate],
                                    "transcription": transcription,
                                    "turn_detection": NSNull()]
        return json(["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]])
    }

    public static func appendAudio(_ pcm16: Data) -> Data {
        json(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    public static func commit() -> Data {
        json(["type": "input_audio_buffer.commit"])
    }

    /// Judge request. `store` is always false, whatever the config says (validation also rejects true).
    public static func judgeBody(_ g: ListenMoreConfig.Gpt, prompt: String) -> Data {
        var body: [String: Any] = [
            "model": g.judgeModel,
            "instructions": judgeInstructions,
            "input": prompt,
            "store": false,
            "max_output_tokens": 200,
            "text": ["format": ["type": "json_schema", "name": "listen_more_cue", "strict": true, "schema": judgeSchema]],
        ]
        if let effort = g.judgeReasoningEffort { body["reasoning"] = ["effort": effort] }
        return json(body)
    }

    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    // MARK: responses

    public enum RealtimeEvent: Equatable {
        case committed(itemId: String)
        case transcript(itemId: String, text: String, audioSeconds: Double?)
        case error
        case other
    }

    public static func parseRealtime(_ data: Data) -> RealtimeEvent {
        guard let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .other }
        switch ev["type"] as? String ?? "" {
        case "input_audio_buffer.committed":
            return .committed(itemId: ev["item_id"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            let usage = ev["usage"] as? [String: Any]
            let secs = usage?["type"] as? String == "duration" ? (usage?["seconds"] as? NSNumber)?.doubleValue : nil
            return .transcript(itemId: ev["item_id"] as? String ?? "", text: ev["transcript"] as? String ?? "", audioSeconds: secs)
        case "error":
            return .error
        default:
            return .other
        }
    }

    public static func parseJudge(_ data: Data) throws -> (JudgeResult, JudgeUsage) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GptError(.judgeDecode) }
        var text = ""
        for item in obj["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for c in item["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "output_text" {
                text += c["text"] as? String ?? ""
            }
        }
        guard let r = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let cue = r["cue"] as? String, judgeLabels.contains(cue) else { throw GptError(.judgeDecode) }
        let conf = (r["confidence"] as? NSNumber)?.doubleValue ?? 0
        let u = obj["usage"] as? [String: Any] ?? [:]
        let usage = JudgeUsage(inputTokens: (u["input_tokens"] as? NSNumber)?.intValue ?? 0,
                               cachedTokens: ((u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? 0,
                               outputTokens: (u["output_tokens"] as? NSNumber)?.intValue ?? 0)
        return (JudgeResult(cue: cue, confidence: conf), usage)
    }
}
