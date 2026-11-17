// swift-tools-version:5.9
import PackageDescription

// ListenMoreKit: MeetingCard's call coach. This package is the single source of the coach code and
// its calibrated defaults (DefaultConfig.swift).
// - CWebRTCVAD: the WebRTC VAD C code.
// - ListenMoreCore: Foundation only, also builds and tests on Linux. Config and generic defaults,
//   VAD / local layer / prosody, cue policy, the GPT client and layer, the engine, the auto-on
//   trigger and CoachSession, which reaches capture, rendering and the key store only through protocols.
// - ListenMoreMac (macOS): the real implementations (AVAudioEngine, ScreenCaptureKit, Core Audio state
//   and process tap, Keychain, NSPanel glow, URLSession transports) and CoachService. Styling is injected.
var products: [Product] = [
    .library(name: "ListenMoreCore", targets: ["ListenMoreCore"]),
]

var targets: [Target] = [
    .target(
        name: "CWebRTCVAD",
        exclude: ["LICENSE"],
        cSettings: [
            .headerSearchPath("."),
            .define("WEBRTC_POSIX"),
        ]
    ),
    .target(name: "ListenMoreCore", dependencies: ["CWebRTCVAD"]),
    .testTarget(name: "ListenMoreCoreTests", dependencies: ["ListenMoreCore"]),
]

#if os(macOS)
products += [
    .library(name: "ListenMoreMac", targets: ["ListenMoreMac"]),
]
targets += [
    .target(name: "ListenMoreMac", dependencies: ["ListenMoreCore"]),
    .testTarget(name: "ListenMoreMacTests", dependencies: ["ListenMoreCore", "ListenMoreMac"]),
    // Paid, opt-in: every test skips unless LISTEN_MORE_LIVE=1 and OPENAI_API_KEY are set.
    .testTarget(name: "ListenMoreLiveTests", dependencies: ["ListenMoreCore", "ListenMoreMac"]),
]
#endif

let package = Package(
    name: "ListenMoreKit",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
