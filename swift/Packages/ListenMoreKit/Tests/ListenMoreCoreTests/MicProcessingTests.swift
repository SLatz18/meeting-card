import Foundation
import XCTest
@testable import ListenMoreCore

final class MicProcessingTests: XCTestCase {
    func os(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    func testMacOS14AndLaterKeepVoiceProcessingAtMinimumDuckingWithAdvancedOff() {
        for v in [os(14), os(14, 4), os(15), os(15, 5), os(26), os(27)] {
            let plan = MicProcessing.plan(macOS: v)
            XCTAssertTrue(plan.voiceProcessing, "\(v)")
            XCTAssertEqual(plan.ducking, MicProcessing.Ducking(advanced: false, level: .min), "\(v)")
        }
    }

    /// Unreachable in shipped builds (the Kit targets macOS 14, MeetingCard macOS 15): with no way to
    /// lower the ducking, the mic runs without voice processing.
    func testBeforeMacOS14RunsWithoutVoiceProcessing() {
        for v in [os(10, 15), os(12), os(13), os(13, 7)] {
            XCTAssertEqual(MicProcessing.plan(macOS: v), MicProcessing(voiceProcessing: false, ducking: nil), "\(v)")
        }
    }

    func testDuckingLevelRawValuesMatchApple() {
        XCTAssertEqual(MicProcessing.DuckingLevel.default.rawValue, 0)
        XCTAssertEqual(MicProcessing.DuckingLevel.min.rawValue, 10)
        XCTAssertEqual(MicProcessing.DuckingLevel.mid.rawValue, 20)
        XCTAssertEqual(MicProcessing.DuckingLevel.max.rawValue, 30)
        XCTAssertEqual(MicProcessing.minimumDucking, MicProcessing.Ducking(advanced: false, level: .min))
    }
}
