import Foundation

/// Reconciles the append-only ASR transcript with the user's free-form edit.
///
/// The live accumulator is the machine-owned branch and `editedText` is the
/// user-owned branch. A new ASR window may extend the machine branch, but it
/// must never replace text the user already corrected or deleted. ClassScribe's
/// accumulator is append-only, so an exact suffix is sufficient and avoids
/// trying to reinterpret a human correction as another ASR hypothesis.
enum LiveTranscriptEditMerger {
    static func merge(
        editedText: String,
        previousASRText: String,
        updatedASRText: String,
    ) -> String {
        guard updatedASRText != previousASRText else { return editedText }

        // This is the normal live-ASR path. Preserve the user's branch byte for
        // byte and add only what the accumulator learned since the last sync.
        guard updatedASRText.hasPrefix(previousASRText) else {
            // A non-append replacement would make it unsafe to infer which
            // existing words were corrected by the person. Keep their version
            // rather than duplicating or restoring machine-owned text. The next
            // append will use this replacement as its new baseline.
            return editedText
        }

        let suffix = String(updatedASRText.dropFirst(previousASRText.count))
        guard !suffix.isEmpty else { return editedText }
        guard !editedText.isEmpty else {
            // If the person intentionally cleared the editor, do not retain the
            // accumulator's leading paragraph separator before the next words.
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A person may start a note before the first ASR window exists. That
        // first machine suffix has no leading separator because its baseline is
        // empty, so insert one without changing normal append-only suffixes.
        let needsSeparator = previousASRText.isEmpty
            && editedText.last?.isWhitespace != true
            && suffix.first?.isWhitespace != true
        return editedText + (needsSeparator ? " " : "") + suffix
    }
}

/// Tracks the machine branch independently from the editable projection. This
/// matters because the accumulator mutates before the observable UI fields are
/// synchronized on the main actor.
struct LiveTranscriptEditReconciler: Equatable {
    private(set) var lastASRText = ""

    mutating func reset(asrText: String = "") {
        lastASRText = asrText
    }

    mutating func reconcile(editedText: String?, updatedASRText: String) -> String? {
        defer { lastASRText = updatedASRText }
        guard let editedText else { return nil }
        return LiveTranscriptEditMerger.merge(
            editedText: editedText,
            previousASRText: lastASRText,
            updatedASRText: updatedASRText,
        )
    }
}
