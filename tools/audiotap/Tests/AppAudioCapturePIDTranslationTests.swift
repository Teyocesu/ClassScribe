@testable import AudioTapLib
import CoreAudio
import Darwin
import XCTest

@available(macOS 14.2, *)
final class AppAudioCapturePIDTranslationTests: XCTestCase {
    // MARK: - static translatePID

    func testTranslatePIDReturnsNilForUnknownPID() {
        // A PID well above any plausibly running process has no CoreAudio
        // process-object entry → the `kAudioObjectUnknown` guard fires.
        XCTAssertNil(AppAudioCapture.translatePID(999_999))
    }

    func testTranslatePIDForCurrentProcessReturnsValidIDOrNil() {
        // Exercises the live `AudioObjectGetPropertyData` path with a real
        // PID. Whether xctest itself has an audio process-object is
        // environment-dependent — some macOS hosts register one, some
        // don't. The function must handle both outcomes without crashing
        // and never return `kAudioObjectUnknown` masquerading as a real ID.
        if let id = AppAudioCapture.translatePID(getpid()) {
            XCTAssertNotEqual(id, AudioObjectID(kAudioObjectUnknown))
        }
    }

    // MARK: - instance translatePIDs

    func testTranslatePIDsThrowsWhenAllPIDsUntranslatable() {
        // All bogus PIDs → empty translated set → must throw rather than
        // hand a `CATapDescription` an empty processObjectIDs array (which
        // would yield a silent tap).
        let capture = AppAudioCapture(
            pids: [999_998, 999_999],
            outputFileDescriptor: -1,
        )
        XCTAssertThrowsError(try capture.translatePIDs()) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "audiotap")
            XCTAssertEqual(ns.code, -1)
            XCTAssertTrue(
                ns.localizedDescription.contains("Failed to translate"),
                "Error description should mention the failure: \(ns.localizedDescription)",
            )
        }
    }

    func testTranslatePIDsEmptyPidsListThrows() {
        // Defensive — production callers always pass at least one PID via
        // `resolveTapPIDs`, but the throw guards against future regressions.
        let capture = AppAudioCapture(pids: [], outputFileDescriptor: -1)
        XCTAssertThrowsError(try capture.translatePIDs())
    }

    // MARK: - CATap source policy

    func testSystemOutputFactoryUsesGlobalTapWithExplicitExclusions() {
        let tap = CATapDescriptionFactory.make(
            for: .systemOutput(excludingProcessObjectIDs: [7, 9]),
        )

        XCTAssertEqual(tap.processes, [7, 9])
    }

    func testSystemOutputExclusionsRevalidateHelpersBeforeEachConstruction() {
        let first = AppAudioCapture.validatedSystemOutputObjectIDs(
            in: [101, 202],
            translate: { pid in [101: AudioObjectID(7), 202: AudioObjectID(9)][pid] },
            roundTrip: { _, _ in true },
        )
        let afterHelperAppeared = AppAudioCapture.validatedSystemOutputObjectIDs(
            in: [101, 202, 303],
            translate: { pid in
                [101: AudioObjectID(7), 202: AudioObjectID(9), 303: AudioObjectID(11)][pid]
            },
            roundTrip: { _, _ in true },
        )

        XCTAssertEqual(first, [7, 9])
        XCTAssertEqual(afterHelperAppeared, [7, 9, 11])
        XCTAssertFalse(first.contains(11), "A prior restart must not reuse or pre-claim a later helper object")
    }

    func testInvalidSelfTranslationProducesNoSyntheticObject() {
        let result = AppAudioCapture.validatedSystemOutputObjectIDs(
            in: [101, 202],
            translate: { pid in pid == 101 ? AudioObjectID(kAudioObjectUnknown) : nil },
            roundTrip: { _, _ in true },
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testApplicationFactoryRemainsProcessMixdown() {
        let tap = CATapDescriptionFactory.make(
            for: .application(processObjectIDs: [7, 9]),
        )

        XCTAssertEqual(tap.processes, [7, 9])
    }
}
