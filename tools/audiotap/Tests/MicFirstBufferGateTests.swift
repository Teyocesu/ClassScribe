@testable import AudioTapLib
import XCTest

final class MicFirstBufferGateTests: XCTestCase {
    func testStartsEmptyAndSignalsOnlyAfterRealFramesAreWritten() {
        let gate = MicFirstBufferGate()
        XCTAssertFalse(gate.hasWrittenFrames)
        XCTAssertFalse(gate.recordWrittenFrames(0))
        XCTAssertFalse(gate.hasWrittenFrames)
        XCTAssertTrue(gate.recordWrittenFrames(512))
        XCTAssertTrue(gate.hasWrittenFrames)
        XCTAssertEqual(gate.snapshot.callbacks, 2)
        XCTAssertEqual(gate.snapshot.frames, 512)
    }

    func testResetClearsReadinessBetweenCaptureAttempts() {
        let gate = MicFirstBufferGate()
        _ = gate.recordWrittenFrames(256)
        gate.reset()
        XCTAssertFalse(gate.hasWrittenFrames)
        XCTAssertEqual(gate.snapshot.callbacks, 0)
        XCTAssertEqual(gate.snapshot.frames, 0)
    }
}
