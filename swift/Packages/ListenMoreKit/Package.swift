// swift-tools-version:5.9
import PackageDescription

// ListenMoreCore is Foundation-only (config, VAD, local rules, cue policy, GPT layer logic, the
// audio-activity trigger) so it also builds and tests on Linux. Everything that touches AppKit,
// AVFoundation, ScreenCaptureKit, Core Audio, URLSession WebSockets or the Keychain lives in
// ListenMoreMac and is only declared on macOS.
var products: [Product] = [
    .library(name: "ListenMoreCore", targets: ["ListenMoreCore"]),
]

var targets: [Target] = [
    .target(name: "ListenMoreCore"),
    .testTarget(name: "ListenMoreCoreTests", dependencies: ["ListenMoreCore"]),
]

#if os(macOS)
products += [
    .library(name: "ListenMoreMac", targets: ["ListenMoreMac"]),
]
targets += [
    .target(name: "ListenMoreMac", dependencies: ["ListenMoreCore"]),
    .testTarget(name: "ListenMoreMacTests", dependencies: ["ListenMoreCore", "ListenMoreMac"]),
    // Paid, opt-in: every test skips unless LISTEN_MORE_LIVE=1 (see .github/workflows/live-openai.yml).
    .testTarget(name: "ListenMoreLiveTests", dependencies: ["ListenMoreCore", "ListenMoreMac"]),
]
#endif

let package = Package(
    name: "ListenMoreKit",
    platforms: [.macOS("15.0")],
    products: products,
    targets: targets
)
