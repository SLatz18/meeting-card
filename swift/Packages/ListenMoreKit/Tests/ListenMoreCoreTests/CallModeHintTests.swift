import Foundation
import XCTest
@testable import ListenMoreCore

final class CallModeHintTests: XCTestCase {
    func callMode(_ transport: AudioDeviceInfo.Transport?, active: Bool? = false, rate: Double? = 48000,
                  output: UInt32? = 2, ourMic: UInt32? = 3) -> Bool {
        CallModeHint.isCallMode(outputTransport: transport, outputInputStreamActive: active, outputSampleRate: rate,
                                outputDevice: output, ourMicDevice: ourMic)
    }

    func testBluetoothWithItsInputActiveAtAHandsFreeRateIsCallMode() {
        for rate in [8000.0, 16000, 24000] { XCTAssertTrue(callMode(.bluetooth, active: true, rate: rate), "\(rate)") }
    }

    func testBluetoothAtFullRateWithItsInputIdleIsNot() {
        for rate in [44100.0, 48000, 96000] { XCTAssertFalse(callMode(.bluetooth, active: false, rate: rate), "\(rate)") }
    }

    /// Undecidable or disagreeing state stays silent: no false tips.
    func testSilentWhenItCannotDecide() {
        XCTAssertFalse(callMode(.bluetooth, active: nil, rate: 16000), "the headset's mic is another device it can't attribute, or unreadable")
        XCTAssertFalse(callMode(.bluetooth, active: true, rate: nil), "sample rate unreadable")
        XCTAssertFalse(callMode(.bluetooth, active: true, rate: 0))
        XCTAssertFalse(callMode(.bluetooth, active: true, rate: 48000), "input active at full rate: volume not known to drop")
        XCTAssertFalse(callMode(.bluetooth, active: false, rate: 16000), "low rate with its input idle: in transition")
        XCTAssertFalse(callMode(nil, active: true, rate: 16000), "transport unreadable")
    }

    func testOnlyBluetoothOutputs() {
        for t: AudioDeviceInfo.Transport? in [.builtIn, .usb, .other, nil] {
            XCTAssertFalse(callMode(t, active: true, rate: 16000), "\(String(describing: t))")
        }
        XCTAssertFalse(callMode(.bluetooth, active: true, output: nil))
    }

    func testNeverWhenTheCoachIsUsingThatHeadsetsMic() {
        XCTAssertFalse(callMode(.bluetooth, active: true, rate: 16000, output: 2, ourMic: 2))
        XCTAssertTrue(callMode(.bluetooth, active: true, rate: 16000, output: 2, ourMic: nil), "coach mic closed or none")
    }

    // MARK: no-mic notice

    func testNoMicStatusOnlyForBluetoothWithoutABuiltInMic() {
        XCTAssertTrue(NoMicNotice.showsStatus(route: .bluetooth, micSource: MicSourceKind.none, builtInMicPresent: false))
        XCTAssertFalse(NoMicNotice.showsStatus(route: .bluetooth, micSource: MicSourceKind.none, builtInMicPresent: true),
                       "a built-in mic set aside (closed lid) is not 'no built-in mic'")
        XCTAssertFalse(NoMicNotice.showsStatus(route: .bluetooth, micSource: .builtIn, builtInMicPresent: true))
        for route in [OutputRoute.speakers, .wiredHeadphones, .other] {
            XCTAssertFalse(NoMicNotice.showsStatus(route: route, micSource: MicSourceKind.none, builtInMicPresent: false), "\(route)")
        }
        XCTAssertFalse(NoMicNotice.showsStatus(route: nil, micSource: nil, builtInMicPresent: false), "mic closed")
    }

    func testNoMicSettingsNoteOnlyWithoutABuiltInMic() {
        XCTAssertTrue(NoMicNotice.showsSettingsNote(builtInMicPresent: false))
        XCTAssertFalse(NoMicNotice.showsSettingsNote(builtInMicPresent: true))
    }

    func testTheNoMicPlanFeedsTheNotice() {
        let mac15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let routes = AudioRoutes(output: AudioDeviceInfo(id: 2, transport: .bluetooth),
                                 defaultInput: AudioDeviceInfo(id: 2, transport: .bluetooth), builtInInput: nil)
        let p = MicPlan.plan(routes: routes, macOS: mac15)
        XCTAssertTrue(NoMicNotice.showsStatus(route: p.route, micSource: p.micSource, builtInMicPresent: routes.builtInInput != nil))
    }

    // MARK: once per call, dismissible

    func testShownOncePerCallUntilDismissed() {
        var t = CallModeHintTracker()
        t.update(call: nil, callMode: true)
        XCTAssertFalse(t.visible, "no call, no hint")
        t.update(call: 1, callMode: false)
        XCTAssertFalse(t.visible)
        t.update(call: 1, callMode: true)
        XCTAssertTrue(t.visible)
        t.update(call: 1, callMode: true)
        XCTAssertTrue(t.visible)
        t.dismiss()
        XCTAssertFalse(t.visible)
        t.update(call: 1, callMode: true)
        XCTAssertFalse(t.visible, "dismissed for this call")
        t.update(call: 2, callMode: true)
        XCTAssertTrue(t.visible, "the next call shows it again")
    }

    func testHidesWhenCallModeEndsAndDoesNotReturnThatCall() {
        var t = CallModeHintTracker()
        t.update(call: 1, callMode: true)
        t.update(call: 1, callMode: false)
        XCTAssertFalse(t.visible)
        t.update(call: 1, callMode: true)
        XCTAssertFalse(t.visible, "once per call")
    }

    func testCallEndHidesIt() {
        var t = CallModeHintTracker()
        t.update(call: 1, callMode: true)
        t.update(call: nil, callMode: true)
        XCTAssertFalse(t.visible)
    }
}
