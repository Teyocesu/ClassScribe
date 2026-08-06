@testable import AudioTapLib
import Darwin
import Dispatch
import Foundation
import XCTest

final class InFlightCallbackGateTests: XCTestCase {
    func testClosedGateRejectsWork() {
        let gate = InFlightCallbackGate()
        XCTAssertFalse(gate.enter())
        XCTAssertEqual(gate.snapshot.inFlight, 0)
    }

    func testCloseWaitsForEnteredCallbackAndRejectsNewWork() {
        let gate = InFlightCallbackGate()
        gate.open()
        XCTAssertTrue(gate.enter())

        let closeStarted = expectation(description: "close started")
        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            closeStarted.fulfill()
            gate.closeAndWait()
            closeFinished.signal()
        }
        wait(for: [closeStarted], timeout: 1)
        for _ in 0 ..< 1000 where gate.snapshot.accepting {
            usleep(1000)
        }

        XCTAssertFalse(gate.snapshot.accepting)
        XCTAssertFalse(gate.enter())
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.05), .timedOut)
        gate.leave()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(gate.snapshot.inFlight, 0)
    }

    func testGateCanReopenForEngineRestart() {
        let gate = InFlightCallbackGate()
        gate.open()
        XCTAssertTrue(gate.enter())
        gate.leave()
        gate.closeAndWait()
        XCTAssertFalse(gate.enter())
        gate.open()
        XCTAssertTrue(gate.enter())
        gate.leave()
    }

    func testTwentyFiveOpenCloseCyclesDrainEveryCallback() {
        let gate = InFlightCallbackGate()
        let queue = DispatchQueue(label: "InFlightCallbackGateTests", attributes: .concurrent)
        for _ in 0 ..< 25 {
            gate.open()
            let callbacks = DispatchGroup()
            for _ in 0 ..< 8 {
                XCTAssertTrue(gate.enter())
                callbacks.enter()
                queue.async {
                    usleep(250)
                    gate.leave()
                    callbacks.leave()
                }
            }
            gate.closeAndWait()
            XCTAssertEqual(callbacks.wait(timeout: .now() + 1), .success)
            XCTAssertFalse(gate.enter())
            XCTAssertFalse(gate.snapshot.accepting)
            XCTAssertEqual(gate.snapshot.inFlight, 0)
        }
    }
}
