import Foundation
import XCTest
@testable import ListenMoreCore

final class MicRouteTests: XCTestCase {
    let mac15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    let mac13 = OperatingSystemVersion(majorVersion: 13, minorVersion: 7, patchVersion: 0)

    let speakersOut = AudioDeviceInfo(id: 1, transport: .builtIn)
    let airPods = AudioDeviceInfo(id: 2, transport: .bluetooth)
    let builtInMic = AudioDeviceInfo(id: 3, transport: .builtIn)
    let usbMic = AudioDeviceInfo(id: 4, transport: .usb)
    let usbOut = AudioDeviceInfo(id: 5, transport: .usb)
    let minimum = MicProcessing(voiceProcessing: true, ducking: MicProcessing.minimumDucking)
    let off = MicProcessing(voiceProcessing: false, ducking: nil)

    func routes(output: AudioDeviceInfo?, source: AudioRoutes.OutputSource = .unknown, input: AudioDeviceInfo?,
                builtIn: AudioDeviceInfo?) -> AudioRoutes {
        AudioRoutes(output: output, outputSource: source, defaultInput: input, builtInInput: builtIn)
    }

    // MARK: routes

    func testOutputRoutes() {
        XCTAssertEqual(MicPlan.route(routes(output: speakersOut, source: .speakers, input: nil, builtIn: nil)), .speakers)
        XCTAssertEqual(MicPlan.route(routes(output: speakersOut, source: .unknown, input: nil, builtIn: nil)), .speakers)
        XCTAssertEqual(MicPlan.route(routes(output: speakersOut, source: .headphones, input: nil, builtIn: nil)), .wiredHeadphones)
        XCTAssertEqual(MicPlan.route(routes(output: airPods, input: nil, builtIn: nil)), .bluetooth)
        XCTAssertEqual(MicPlan.route(routes(output: usbOut, input: nil, builtIn: nil)), .other)
        XCTAssertEqual(MicPlan.route(routes(output: nil, input: nil, builtIn: nil)), .other)
        XCTAssertTrue(OutputRoute.bluetooth.isHeadphones)
        XCTAssertTrue(OutputRoute.wiredHeadphones.isHeadphones)
        XCTAssertFalse(OutputRoute.speakers.isHeadphones)
        XCTAssertFalse(OutputRoute.other.isHeadphones)
    }

    // MARK: headphones: no voice processing; Bluetooth output uses the Mac's mic (B1) or none (B3)

    func testBluetoothOutputUsesTheBuiltInMicEvenWhenTheHeadsetIsTheDefaultInput() {
        for input in [airPods, builtInMic, usbMic] {
            let p = MicPlan.plan(routes: routes(output: airPods, input: input, builtIn: builtInMic), macOS: mac15)
            XCTAssertEqual(p, MicPlan(route: .bluetooth, micSource: .builtIn, device: builtInMic.id, processing: off), "\(input)")
        }
    }

    func testBluetoothOutputWithoutABuiltInMicRunsOnCallAudioOnly() {
        for input in [airPods, usbMic, nil] {
            let p = MicPlan.plan(routes: routes(output: airPods, input: input, builtIn: nil), macOS: mac15)
            XCTAssertEqual(p, MicPlan(route: .bluetooth, micSource: .none, device: nil, processing: off))
        }
    }

    func testWiredHeadphonesUseTheSystemInputWithoutVoiceProcessing() {
        let p = MicPlan.plan(routes: routes(output: speakersOut, source: .headphones, input: usbMic, builtIn: builtInMic), macOS: mac15)
        XCTAssertEqual(p, MicPlan(route: .wiredHeadphones, micSource: .systemDefault, device: usbMic.id, processing: off))
        let bt = MicPlan.plan(routes: routes(output: speakersOut, source: .headphones, input: airPods, builtIn: builtInMic), macOS: mac15)
        XCTAssertEqual(bt, MicPlan(route: .wiredHeadphones, micSource: .builtIn, device: builtInMic.id, processing: off))
    }

    func testDiagnosticsNeverApplyToHeadphones() {
        let d = MicDiagnostics(speakerVoiceProcessing: true, speakerMicSource: .builtIn)
        for out in [(airPods, AudioRoutes.OutputSource.unknown), (speakersOut, .headphones)] {
            let p = MicPlan.plan(routes: routes(output: out.0, source: out.1, input: usbMic, builtIn: builtInMic), macOS: mac15,
                                 diagnostics: d)
            XCTAssertFalse(p.processing.voiceProcessing)
        }
    }

    // MARK: speakers: standard unchanged; diagnostics switch voice processing and the mic

    func testSpeakersStandardIsVoiceProcessingAtMinimumWithTheSystemInput() {
        let p = MicPlan.plan(routes: routes(output: speakersOut, source: .speakers, input: builtInMic, builtIn: builtInMic), macOS: mac15)
        XCTAssertEqual(p, MicPlan(route: .speakers, micSource: .systemDefault, device: builtInMic.id, processing: minimum))
        let usb = MicPlan.plan(routes: routes(output: usbOut, input: usbMic, builtIn: builtInMic), macOS: mac15)
        XCTAssertEqual(usb, MicPlan(route: .other, micSource: .systemDefault, device: usbMic.id, processing: minimum))
    }

    func testSpeakersNeverOpenABluetoothDefaultInput() {
        let p = MicPlan.plan(routes: routes(output: speakersOut, source: .speakers, input: airPods, builtIn: builtInMic), macOS: mac15)
        XCTAssertEqual(p, MicPlan(route: .speakers, micSource: .builtIn, device: builtInMic.id, processing: minimum))
        let none = MicPlan.plan(routes: routes(output: speakersOut, source: .speakers, input: airPods, builtIn: nil), macOS: mac15)
        XCTAssertEqual(none, MicPlan(route: .speakers, micSource: .none, device: nil, processing: off))
    }

    func testEveryDiagnosticsCombinationOnSpeakers() {
        let r = routes(output: speakersOut, source: .speakers, input: usbMic, builtIn: builtInMic)
        let cases: [(Bool?, MicDiagnostics.Source, MicSourceKind, UInt32, MicProcessing)] = [
            (nil, .systemDefault, .systemDefault, usbMic.id, minimum),
            (true, .systemDefault, .systemDefault, usbMic.id, minimum),
            (false, .systemDefault, .systemDefault, usbMic.id, off),
            (nil, .builtIn, .builtIn, builtInMic.id, minimum),
            (true, .builtIn, .builtIn, builtInMic.id, minimum),
            (false, .builtIn, .builtIn, builtInMic.id, off),
        ]
        for (vp, source, kind, device, processing) in cases {
            let p = MicPlan.plan(routes: r, macOS: mac15, diagnostics: MicDiagnostics(speakerVoiceProcessing: vp, speakerMicSource: source))
            XCTAssertEqual(p, MicPlan(route: .speakers, micSource: kind, device: device, processing: processing), "\(String(describing: vp)) \(source)")
        }
        let noBuiltIn = MicPlan.plan(routes: routes(output: speakersOut, source: .speakers, input: usbMic, builtIn: nil), macOS: mac15,
                                     diagnostics: MicDiagnostics(speakerMicSource: .builtIn))
        XCTAssertEqual(noBuiltIn.micSource, .systemDefault, "no built-in mic to pick: the system input")
    }

    /// Unreachable in shipped builds (Kit macOS 14, app macOS 15).
    func testBeforeMacOS14SpeakersRunWithoutVoiceProcessing() {
        let p = MicPlan.plan(routes: routes(output: speakersOut, source: .speakers, input: builtInMic, builtIn: builtInMic), macOS: mac13,
                             diagnostics: MicDiagnostics(speakerVoiceProcessing: true))
        XCTAssertEqual(p.processing, off)
    }

    /// Over every combination: no Bluetooth device is ever opened, headphones and no-mic plans never
    /// use voice processing, and a plan with a device has a source.
    func testInvariantsOverEveryCombination() {
        let outputs: [AudioDeviceInfo?] = [nil, speakersOut, airPods, usbOut, AudioDeviceInfo(id: 6, transport: .other)]
        let inputs: [AudioDeviceInfo?] = [nil, builtInMic, airPods, usbMic, AudioDeviceInfo(id: 7, transport: .bluetooth)]
        let builtIns: [AudioDeviceInfo?] = [nil, builtInMic]
        let sources: [AudioRoutes.OutputSource] = [.speakers, .headphones, .unknown]
        let diags = [nil, true, false].flatMap { vp in MicDiagnostics.Source.allCases.map { MicDiagnostics(speakerVoiceProcessing: vp, speakerMicSource: $0) } }
        let bluetoothIds: Set<UInt32> = [2, 7]
        var count = 0
        for o in outputs { for i in inputs { for b in builtIns { for s in sources { for d in diags { for v in [mac13, mac15] {
            let p = MicPlan.plan(routes: routes(output: o, source: s, input: i, builtIn: b), macOS: v, diagnostics: d)
            count += 1
            if let device = p.device { XCTAssertFalse(bluetoothIds.contains(device)) }
            XCTAssertEqual(p.device == nil, p.micSource == .none)
            if p.route.isHeadphones || p.micSource == .none { XCTAssertFalse(p.processing.voiceProcessing) }
            if p.route == .bluetooth { XCTAssertNotEqual(p.micSource, .systemDefault) }
            if p.processing.voiceProcessing { XCTAssertEqual(p.processing.ducking, MicProcessing.minimumDucking) }
        } } } } } }
        XCTAssertEqual(count, 5 * 5 * 2 * 3 * 6 * 2)
    }

    // MARK: restart policy

    func testOneChangeEvaluatesAfterTheDebounce() {
        var p = MicRestartPolicy()
        XCTAssertEqual(p.fire(at: 0), .idle)
        let due = p.changed(at: 10)
        XCTAssertEqual(due, 10.5, accuracy: 1e-9)
        XCTAssertEqual(p.fire(at: 10.2), .wait(until: 10.5))
        XCTAssertEqual(p.fire(at: 10.5), .evaluate)
        XCTAssertEqual(p.fire(at: 11), .idle)
    }

    func testAStormOfChangesEvaluatesOnceItIsQuiet() {
        var p = MicRestartPolicy()
        var evaluations: [Double] = []
        var due: Double?
        var t = 0.0
        while t < 20 {
            if t < 3, (t * 10).rounded().truncatingRemainder(dividingBy: 2) == 0 { due = p.changed(at: t) }
            if let d = due, t + 1e-9 >= d {
                switch p.fire(at: t) {
                case .evaluate: evaluations.append(t); due = nil
                case .wait(let u): due = u
                case .idle: due = nil
                }
            }
            t = (t + 0.1 * 1).rounded(toPlaces: 1)
        }
        XCTAssertEqual(evaluations.count, 1)
        XCTAssertEqual(evaluations.first ?? 0, 3.3, accuracy: 0.11, "half a second after the last change")
    }

    /// A route flapping every 0.6 s for two minutes: at most 3 restarts in any 30 s (no glitch loop).
    func testFlappingRouteRestartsAreCapped() {
        var p = MicRestartPolicy()
        var restarts: [Double] = []
        var due: Double?
        var t = 0.0
        while t < 120 {
            if (t * 10).rounded().truncatingRemainder(dividingBy: 6) == 0 { due = p.changed(at: t) }
            if let d = due, t + 1e-9 >= d {
                switch p.fire(at: t) {
                case .evaluate:
                    restarts.append(t)
                    p.didRestart(at: t)
                    due = nil
                case .wait(let u): due = u
                case .idle: due = nil
                }
            }
            t = (t + 0.1).rounded(toPlaces: 1)
        }
        XCTAssertGreaterThan(restarts.count, 3, "it still follows the route")
        XCTAssertLessThanOrEqual(restarts.count, 3 * (120 / 30) + 3, "unthrottled it would be 200")
        for (a, b) in zip(restarts, restarts.dropFirst(3)) {
            XCTAssertGreaterThanOrEqual(b - a, 30 - 1e-9, "no 4 restarts inside 30 s")
        }
        for (a, b) in zip(restarts, restarts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.5 - 1e-9, "never closer than the debounce")
        }
    }

    func testRestartOnlyForANewPlanOrADeadInput() {
        let a = MicPlan(route: .speakers, micSource: .systemDefault, device: 3, processing: minimum)
        let b = MicPlan(route: .bluetooth, micSource: .builtIn, device: 3, processing: off)
        let none = MicPlan(route: .bluetooth, micSource: .none, device: nil, processing: off)
        XCTAssertFalse(MicRestartPolicy.shouldRestart(open: a, next: a, inputRunning: true), "its own device changes")
        XCTAssertTrue(MicRestartPolicy.shouldRestart(open: a, next: b, inputRunning: true))
        XCTAssertTrue(MicRestartPolicy.shouldRestart(open: a, next: a, inputRunning: false))
        XCTAssertFalse(MicRestartPolicy.shouldRestart(open: none, next: none, inputRunning: false), "no input to be running")
        XCTAssertTrue(MicRestartPolicy.shouldRestart(open: nil, next: a, inputRunning: false))
    }
}

private extension Double {
    func rounded(toPlaces n: Int) -> Double {
        let f = pow(10, Double(n))
        return (self * f).rounded() / f
    }
}
