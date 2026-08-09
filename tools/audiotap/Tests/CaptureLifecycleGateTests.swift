@testable import AudioTapLib
import XCTest

final class CaptureLifecycleGateTests: XCTestCase {
    func testCancelInvalidatesQueuedGeneration() throws {
        let gate = CaptureLifecycleGate()
        let generation = try XCTUnwrap(gate.begin())

        XCTAssertTrue(gate.isActive(generation))
        gate.cancel()

        XCTAssertFalse(gate.isActive(generation))
        XCTAssertNil(gate.activeGeneration)
    }

    func testOldRetryCannotAffectReusedCapture() throws {
        let gate = CaptureLifecycleGate()
        let old = try XCTUnwrap(gate.begin())
        gate.cancel()
        let current = try XCTUnwrap(gate.begin())

        XCTAssertFalse(gate.isActive(old))
        XCTAssertTrue(gate.isActive(current))
        gate.end(old)
        XCTAssertTrue(gate.isActive(current), "a stale completion must not end the current capture")
    }

    func testCaptureLifecycleIsSingleFlight() throws {
        let gate = CaptureLifecycleGate()
        let generation = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.begin())

        gate.end(generation)
        XCTAssertNotNil(gate.begin())
    }
}
