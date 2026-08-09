@testable import AudioTapLib
import Foundation
import XCTest

final class MicCaptureErrorTests: XCTestCase {
    func testNoInputDeviceDescription() {
        let error = MicCaptureError.noInputDevice
        XCTAssertEqual(error.errorDescription, "No microphone hardware available")
    }

    func testFirstBufferTimeoutIsActionable() {
        let error = MicCaptureError.firstBufferTimeout(timeout: 2.5, callbacks: 0, frames: 0)
        XCTAssertTrue(error.localizedDescription.contains("no entregó audio"))
        XCTAssertTrue(error.localizedDescription.contains("2.5"))
    }

    func testRestartLimitIsActionable() {
        let error = MicCaptureError.restartLimitExceeded(maximum: 3)
        XCTAssertTrue(error.localizedDescription.contains("3 veces"))
    }

    func testDisconnectedSelectedDeviceIsActionable() {
        let error = MicCaptureError.deviceUnavailable(uid: "removed-device")
        XCTAssertTrue(error.localizedDescription.contains("ya no está disponible"))
        XCTAssertTrue(error.localizedDescription.contains("elige otro"))
    }

    func testDeviceSelectionFailureIncludesStatus() {
        let error = MicCaptureError.deviceSelectionFailed(uid: "busy-device", status: -50)
        XCTAssertTrue(error.localizedDescription.contains("-50"))
        XCTAssertTrue(error.localizedDescription.contains("Elige otro"))
    }
}
