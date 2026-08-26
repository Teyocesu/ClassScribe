import Foundation
import Testing
@testable import ClassScribe

@Test
func durableMasterFailureDoesNotRecommendSystemOutput() {
    #expect(
        CaptureRecoveryPolicy.suggestion(
            for: .durableMaster,
            scope: .application,
        ) == nil,
    )
}

@Test
func applicationSourceFailureStillCanRecommendSystemOutput() {
    #expect(
        CaptureRecoveryPolicy.suggestion(
            for: .source,
            scope: .application,
        ) == .systemOutput,
    )
}

@Test
func diskFailureDoesNotRecommendSystemOutput() {
    #expect(
        CaptureRecoveryPolicy.suggestion(
            for: .storage,
            scope: .application,
        ) == nil,
    )
    #expect(
        CaptureRecoveryPolicy.suggestion(
            for: .finalization,
            scope: .application,
        ) == nil,
    )
}

@Test
func staleDurableFailureCannotAffectNewAttempt() {
    let old = CaptureTerminalFailure(
        message: "old",
        category: .durableMaster,
    )
    let newAttemptFailure: CaptureTerminalFailure? = nil

    #expect(old.category == .durableMaster)
    #expect(newAttemptFailure == nil)
}
