import Foundation
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

/// Paid, opt-in checks against the real OpenAI API. Skipped unless LISTEN_MORE_LIVE=1 and a key is
/// in the environment (only the workflow_dispatch "live-openai" workflow sets these). Inputs are
/// synthetic and content-free: counting words, as a scripted prompt and as macOS `say` speech. Nothing is printed except pass/fail.
final class OpenAILiveTests: XCTestCase {
    var key: APIKey!
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LISTEN_MORE_LIVE"] == "1", let k = env["OPENAI_API_KEY"].flatMap(APIKey.init) else {
            throw XCTSkip("live OpenAI tests need LISTEN_MORE_LIVE=1 and OPENAI_API_KEY")
        }
        key = k
        config = try ListenMoreConfig.builtIn()
    }

    func testKeyCheck() async {
        let ok = await KeyValidator.check(key.value)
        XCTAssertEqual(ok, .ok)
        let bad = await KeyValidator.check("sk-not-a-real-key-000000000000000000")
        XCTAssertEqual(bad, .rejected)
        let empty = await KeyValidator.check("   ")
        XCTAssertEqual(empty, .empty)
    }

    func testJudgeReturnsSchemaConformingCue() {
        let judge = ResponsesJudge(config: config, key: key)
        let prompt = """
        TRANSCRIPT (oldest first):
        [-12.0s] OTHERS: one two three?
        [- 3.0s] ME: four five six.

        LOCAL_FLAGS: prosody_flagged=yes loudness_jump_db=8.0 rate_jump_pct=30.0 recent_overlaps=none
        PENDING_QUESTION: yes ME_ANSWERED_SINCE: no
        TRIGGER: me_turn
        """
        let done = expectation(description: "judge")
        judge.judge(prompt: prompt) { result in
            switch result {
            case .success(let (r, usage)):
                XCTAssertTrue(OpenAIWire.judgeLabels.contains(r.cue))
                XCTAssertGreaterThan(usage.inputTokens, 0)
            case .failure(let e):
                XCTFail("judge failed: \(e)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }

    func testRealtimeTranscribesSyntheticSpeech() throws {
        let samples = try Self.say("One two three four five six seven eight nine ten.", sampleRate: config.audio.sampleRate)
        let tx = RealtimeTranscriber(config: config, key: key)
        let got = expectation(description: "transcript")
        var text = ""
        tx.start(onText: { t, ref in
            text = t
            XCTAssertEqual(ref ?? -1, 9.5, accuracy: 0.001)
            got.fulfill()
        }, onError: { e in XCTFail("realtime error: \(e)") })
        Thread.sleep(forTimeInterval: 1)
        for i in stride(from: 0, to: samples.count, by: 2400) {
            tx.sendAudio(PCM.pcm16(samples[i..<min(i + 2400, samples.count)]))
        }
        tx.commit(refT: 9.5)
        wait(for: [got], timeout: 30)
        tx.close()
        XCTAssertTrue(text.lowercased().contains("five"))
    }

    /// Synthetic speech from macOS `say`, as mono Float32 at `sampleRate` (temp file removed).
    static func say(_ text: String, sampleRate: Int) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lm-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@\(sampleRate)", text]
        try p.run()
        p.waitUntilExit()
        let data = try Data(contentsOf: url)
        // Float32 WAV from `say`: find the "data" chunk.
        guard let r = data.range(of: Data("data".utf8)) else { return [] }
        let start = r.upperBound + 4
        return data[start...].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
