import Foundation
import XCTest
import ListenMoreCore
import ListenMoreMac

/// Paid, opt-in checks against the real OpenAI API. Skipped unless LISTEN_MORE_LIVE=1 and a key is
/// in the environment. Inputs are synthetic and content-free: counting words, as a scripted prompt
/// and as macOS `say` speech. Nothing is printed except pass/fail.
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

    func testJudgeReturnsSchemaConformingCue() async throws {
        let judge = LiveJudge(config: config, key: key, http: URLSessionHTTPTransport())
        let prompt = """
        TRANSCRIPT (oldest first):
        [-12.0s] OTHERS: one two three?
        [- 3.0s] ME: four five six.

        LOCAL_FLAGS: prosody_flagged=yes loudness_jump_db=8.0 rate_jump_pct=30.0 recent_overlaps=none
        PENDING_QUESTION: yes ME_ANSWERED_SINCE: no
        TRIGGER: me_turn
        """
        let (r, usage) = try await judge.judge(prompt: prompt)
        XCTAssertTrue(GptJudgeSpec.labels.contains(r.cue))
        XCTAssertGreaterThan(usage.inputTokens, 0)
    }

    func testRealtimeTranscribesSyntheticSpeech() async throws {
        let samples = try Self.say("One two three four five six seven eight nine ten.", sampleRate: config.audio.sampleRate)
        let box = TextBox()
        let tx = LiveTranscriber(config: config, key: key, speaker: .others, connector: URLSessionWebSocketConnector()) { ev in
            if case .text(_, let t, let ref) = ev { box.set(t, ref) }
        }
        try await tx.start()
        for i in stride(from: 0, to: samples.count, by: 2400) {
            try await tx.sendAudio(AudioMath.pcm16Data(samples[i..<min(i + 2400, samples.count)]))
        }
        try await tx.commit(refT: 9.5)
        let deadline = Date().addingTimeInterval(30)
        while box.get() == nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        await tx.close()
        let got = try XCTUnwrap(box.get())
        XCTAssertEqual(got.1, 9.5, accuracy: 0.001)
        XCTAssertTrue(got.0.lowercased().contains("five"))
    }

    final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (String, TimeInterval)?
        func set(_ t: String, _ ref: TimeInterval) { lock.withLock { value = (t, ref) } }
        func get() -> (String, TimeInterval)? { lock.withLock { value } }
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
        guard let r = data.range(of: Data("data".utf8)) else { return [] }
        let start = r.upperBound + 4
        return data[start...].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
