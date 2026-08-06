@testable import AudioTapLib
import Darwin
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
        let closeFinished = expectation(description: "close finished")
        DispatchQueue.global().async {
            closeStarted.fulfill()
            gate.closeAndWait()
            closeFinished.fulfill()
        }
        wait(for: [closeStarted], timeout: 1)
        for _ in 0 ..< 1000 where gate.snapshot.accepting {
            usleep(1000)
        }

        XCTAssertFalse(gate.snapshot.accepting)
        XCTAssertFalse(gate.enter())
        XCTAssertEqual(XCTWaiter.wait(for: [closeFinished], timeout: 0.05), .timedOut)
        gate.leave()
        wait(for: [closeFinished], timeout: 1)
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
