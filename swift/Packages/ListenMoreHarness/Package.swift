// swift-tools-version:5.9
import PackageDescription

// ListenMoreHarness: a standalone voice harness for the coach pipeline. It drives ListenMoreCore's
// CoachSession with two synthetic streams (You on the mic, Them on the call) and scores
// transcription, speaker identification and coaching. Offline (the default) is deterministic and
// needs no network; live uses real OpenAI TTS and realtime transcription. No devices, no Mac.
// Not part of the app: nothing here is linked into MeetingCard.
var harnessDependencies: [Target.Dependency] = [
    .product(name: "ListenMoreCore", package: "ListenMoreKit"),
]

var targets: [Target] = []

#if os(Linux)
// Live mode's WebSocket on Linux: Foundation's URLSessionWebSocketTask needs a libcurl built with
// ws/wss, which distro builds lack, so the harness speaks RFC 6455 over system OpenSSL.
targets.append(.systemLibrary(name: "CHarnessTLS", pkgConfig: "openssl", providers: [.apt(["libssl-dev"])]))
harnessDependencies.append("CHarnessTLS")
#endif

targets += [
    .target(name: "ListenMoreHarness", dependencies: harnessDependencies),
    .executableTarget(name: "lm-harness", dependencies: ["ListenMoreHarness"]),
    .testTarget(name: "ListenMoreHarnessTests", dependencies: ["ListenMoreHarness"]),
]

let package = Package(
    name: "ListenMoreHarness",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lm-harness", targets: ["lm-harness"]),
    ],
    dependencies: [
        .package(path: "../ListenMoreKit"),
    ],
    targets: targets
)
