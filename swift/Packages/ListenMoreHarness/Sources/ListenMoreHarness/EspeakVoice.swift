import Foundation
import ListenMoreCore

/// Offline speech with real word timing and pauses, from a local `espeak-ng` (free, deterministic, no
/// network). A diagnostic between the synthetic signal and live TTS: it reproduces timing effects
/// such as a re-onset after a comma. The audio comes through a pipe and stays in memory.
public enum EspeakVoice {
    public static let paths = ["/usr/bin/espeak-ng", "/usr/local/bin/espeak-ng", "/opt/homebrew/bin/espeak-ng"]
    static let voices: [Voice: String] = [.you: "en-us", .themA: "en-us+f3", .themB: "en-gb"]

    public static var executable: String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public static func speak(_ text: String, voice: Voice, sampleRate: Int) throws -> [Float] {
        guard let exe = executable else { throw HarnessError.script("espeak-ng is not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-v", voices[voice] ?? "en-us", "-s", "165", "--stdout", text]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, data.count > 44 else { throw HarnessError.script("espeak-ng failed") }
        // A WAV header (44 bytes; the length fields are unset on a pipe), then 16-bit mono at 22050 Hz.
        let pcm = data.dropFirst(44)
        var samples = [Float](repeating: 0, count: pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            for (i, s) in raw.bindMemory(to: Int16.self).enumerated() where i < samples.count {
                samples[i] = Float(Int16(littleEndian: s)) / 32768
            }
        }
        return AudioMath.resample(samples[...], from: 22050, to: sampleRate)
    }
}
