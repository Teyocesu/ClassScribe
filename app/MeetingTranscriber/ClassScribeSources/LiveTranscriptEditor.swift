import AppKit
import SwiftUI

/// Pure policy used when SwiftUI supplies a newer live transcript to the
/// AppKit editor. `NSTextView` selections use UTF-16 offsets, so the policy does
/// the same and safely clamps a selection if a non-append update is shorter.
enum LiveTranscriptEditorUpdatePolicy {
    enum ViewportAction: Equatable {
        case preserveCurrentPosition
        case followEnd
    }

    struct Plan: Equatable {
        var selections: [NSRange]
        var viewportAction: ViewportAction

        var selection: NSRange {
            selections.first ?? NSRange(location: 0, length: 0)
        }
    }

    static func plan(
        selectedRange: NSRange,
        updatedText: String,
        isFollowing: Bool,
    ) -> Plan {
        plan(selectedRanges: [selectedRange], updatedText: updatedText, isFollowing: isFollowing)
    }

    static func plan(
        selectedRanges: [NSRange],
        updatedText: String,
        isFollowing: Bool,
    ) -> Plan {
        let textLength = updatedText.utf16.count
        return Plan(
            selections: selectedRanges.isEmpty
                ? [NSRange(location: textLength, length: 0)]
                : selectedRanges.map { clampedSelection($0, utf16Length: textLength) },
            viewportAction: isFollowing ? .followEnd : .preserveCurrentPosition,
        )
    }

    static func clampedSelection(_ selection: NSRange, utf16Length: Int) -> NSRange {
        let textLength = max(0, utf16Length)
        guard selection.location != NSNotFound else {
            return NSRange(location: textLength, length: 0)
        }
        let location = min(selection.location, textLength)
        let availableLength = textLength - location
        return NSRange(location: location, length: min(selection.length, availableLength))
    }

    /// Completes an external append that was deferred while an input method
    /// owned marked text. The composed human text stays authoritative.
    static func mergingDeferredExternalText(
        editorText: String,
        previousText: String,
        updatedText: String,
    ) -> String {
        LiveTranscriptEditMerger.merge(
            editedText: editorText,
            previousASRText: previousText,
            updatedASRText: updatedText,
        )
    }
}

/// Converts responder transitions into review-state changes. AppKit may assign
/// first responder to a newly inserted text view without user input, so the
/// first focus transition is silent unless it came from keyboard traversal.
struct LiveTranscriptFocusIntentGate: Equatable {
    enum Transition: Equatable {
        case ignoredInitialAutomaticFocus
        case reviewBegan
        case reviewEnded
    }

    private var handledInitialFocus = false
    private var isReviewing = false

    static func isKeyboardFocusTraversal(
        eventType: NSEvent.EventType?,
        keyCode: UInt16?,
    ) -> Bool {
        eventType == .keyDown && keyCode == 48 // Tab and Shift-Tab
    }

    mutating func responderBecame(explicitKeyboardIntent: Bool) -> Transition? {
        guard !isReviewing else { return nil }
        if handledInitialFocus || explicitKeyboardIntent {
            handledInitialFocus = true
            isReviewing = true
            return .reviewBegan
        }
        handledInitialFocus = true
        return .ignoredInitialAutomaticFocus
    }

    mutating func userExpressedReviewIntent() -> Transition? {
        handledInitialFocus = true
        guard !isReviewing else { return nil }
        isReviewing = true
        return .reviewBegan
    }

    mutating func responderResigned() -> Transition? {
        guard isReviewing else { return nil }
        isReviewing = false
        return .reviewEnded
    }
}

/// Editable live transcript backed by `NSTextView` so an external ASR append
/// does not move the user's caret, selection, or viewport while they type.
@MainActor
struct LiveTranscriptEditor: NSViewRepresentable {
    @Binding private var text: String
    @Binding private var isEditing: Bool
    @Binding private var isFollowing: Bool
    private var onFinalize: @MainActor () -> Void

    init(
        text: Binding<String>,
        isEditing: Binding<Bool>,
        isFollowing: Binding<Bool>,
        onFinalize: @escaping @MainActor () -> Void = {},
    ) {
        _text = text
        _isEditing = isEditing
        _isFollowing = isFollowing
        self.onFinalize = onFinalize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isEditing: $isEditing,
            isFollowing: $isFollowing,
            onFinalize: onFinalize,
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        let textView = FocusReportingTextView(frame: scrollView.contentView.bounds)
        textView.delegate = context.coordinator
        textView.focusDidChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.setEditing(focused)
        }
        textView.automaticFocusDidOccur = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.handleAutomaticFocus(in: textView)
        }
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude,
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude,
        )
        textView.setAccessibilityLabel("Transcripción en vivo editable")
        textView.setAccessibilityHelp(
            "El seguimiento se pausa al editar para conservar el cursor y la posición visible.",
        )

        scrollView.documentView = textView
        context.coordinator.observeUserScrolling(in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.updateBindings(
            text: $text,
            isEditing: $isEditing,
            isFollowing: $isFollowing,
            onFinalize: onFinalize,
        )
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.synchronizeFollowing(in: textView)
        context.coordinator.receiveExternalText(text, in: textView, scrollView: scrollView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingUserScrolling()
        if let textView = scrollView.documentView as? FocusReportingTextView {
            // Publish marked/deferred text before the delegate is disconnected.
            // `onFinalize` runs after the binding update, so the owner can flush
            // the exact final value synchronously if this view is disappearing.
            coordinator.finalizeEditing(in: textView, scrollView: scrollView)
            textView.focusDidChange = nil
            textView.automaticFocusDidOccur = nil
            textView.delegate = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private var isEditing: Binding<Bool>
        private var isFollowing: Binding<Bool>
        private var isApplyingExternalText = false
        private var isResignScheduled = false
        private var lastFollowing = false
        private var lastSynchronizedText: String
        private var pendingExternalBaseText: String?
        private var pendingExternalText: String?
        private var onFinalize: @MainActor () -> Void

        init(
            text: Binding<String>,
            isEditing: Binding<Bool>,
            isFollowing: Binding<Bool>,
            onFinalize: @escaping @MainActor () -> Void = {},
        ) {
            self.text = text
            self.isEditing = isEditing
            self.isFollowing = isFollowing
            self.onFinalize = onFinalize
            lastSynchronizedText = text.wrappedValue
        }

        fileprivate func updateBindings(
            text: Binding<String>,
            isEditing: Binding<Bool>,
            isFollowing: Binding<Bool>,
            onFinalize: @escaping @MainActor () -> Void,
        ) {
            self.text = text
            self.isEditing = isEditing
            self.isFollowing = isFollowing
            self.onFinalize = onFinalize
        }

        func setEditing(_ editing: Bool) {
            if isEditing.wrappedValue != editing {
                isEditing.wrappedValue = editing
            }
            if editing {
                setFollowing(false)
            }
        }

        private func setFollowing(_ following: Bool) {
            guard isFollowing.wrappedValue != following else { return }
            isFollowing.wrappedValue = following
        }

        func synchronizeFollowing(in textView: NSTextView) {
            let following = isFollowing.wrappedValue
            if following,
               textView.window?.firstResponder === textView,
               !isResignScheduled {
                // Resigning synchronously from updateNSView would make the
                // focus callback mutate SwiftUI state during a view update.
                isResignScheduled = true
                Task { @MainActor [weak self, weak textView] in
                    guard let self else { return }
                    self.isResignScheduled = false
                    guard self.isFollowing.wrappedValue,
                          let textView,
                          let window = textView.window,
                          window.firstResponder === textView else { return }
                    _ = window.makeFirstResponder(nil)
                }
            }
            if following, !lastFollowing {
                scrollToEnd(in: textView)
            }
            lastFollowing = following
        }

        /// AppKit can assign first responder to the editor as it is attached to
        /// the window. That focus is not review intent: release it on the next
        /// main-actor turn and align the existing transcript to its end. A real
        /// click/key/accessibility action flips `isFollowing` first, so this
        /// scheduled cleanup then leaves the user's focus and viewport intact.
        func handleAutomaticFocus(in textView: NSTextView) {
            guard isFollowing.wrappedValue, !isResignScheduled else { return }
            isResignScheduled = true
            Task { @MainActor [weak self, weak textView] in
                guard let self else { return }
                self.isResignScheduled = false
                guard self.isFollowing.wrappedValue, let textView else { return }
                if let window = textView.window,
                   window.firstResponder === textView {
                    _ = window.makeFirstResponder(nil)
                }
                self.scrollToEnd(in: textView)
            }
        }

        func observeUserScrolling(in scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userDidStartLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
            )
        }

        func stopObservingUserScrolling() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSScrollView.willStartLiveScrollNotification,
                object: nil,
            )
        }

        @objc private func userDidStartLiveScroll(_: Notification) {
            setFollowing(false)
        }

        func receiveExternalText(
            _ updatedText: String,
            in textView: NSTextView,
            scrollView: NSScrollView,
        ) {
            guard textView.string != updatedText else {
                if pendingExternalText == nil, !textView.hasMarkedText() {
                    lastSynchronizedText = updatedText
                }
                return
            }

            if textView.hasMarkedText() {
                if pendingExternalBaseText == nil {
                    pendingExternalBaseText = lastSynchronizedText
                }
                pendingExternalText = updatedText
                return
            }

            let targetText: String
            if let previousText = pendingExternalBaseText {
                targetText = LiveTranscriptEditorUpdatePolicy.mergingDeferredExternalText(
                    editorText: textView.string,
                    previousText: previousText,
                    updatedText: updatedText,
                )
                pendingExternalBaseText = nil
                pendingExternalText = nil
            } else {
                targetText = updatedText
            }
            applyExternalText(targetText, in: textView, scrollView: scrollView)
            lastSynchronizedText = targetText
            if targetText != updatedText {
                publishHumanText(targetText)
            }
        }

        /// Synchronously commits any active input-method composition, merges a
        /// deferred ASR append, and publishes the final human-owned text. The
        /// return value and callback make persistence ordering directly testable.
        @discardableResult
        func finalizeEditing(in textView: NSTextView, scrollView: NSScrollView) -> String {
            // SwiftUI may update the Binding and dismantle this representable
            // before delivering one final `updateNSView`. Capture that latest
            // ASR branch before `unmarkText` can emit a delegate callback that
            // publishes the human composition back into the same Binding.
            let latestBindingText = text.wrappedValue
            let previousExternalText = pendingExternalBaseText ?? lastSynchronizedText
            if textView.hasMarkedText() {
                isApplyingExternalText = true
                textView.unmarkText()
                isApplyingExternalText = false
            }

            let finalizedText = LiveTranscriptEditorUpdatePolicy.mergingDeferredExternalText(
                editorText: textView.string,
                previousText: previousExternalText,
                updatedText: latestBindingText,
            )
            applyExternalText(finalizedText, in: textView, scrollView: scrollView)
            pendingExternalBaseText = nil
            pendingExternalText = nil
            lastSynchronizedText = finalizedText
            publishHumanText(finalizedText)
            setEditing(false)
            onFinalize()
            return finalizedText
        }

        private func applyExternalText(
            _ updatedText: String,
            in textView: NSTextView,
            scrollView: NSScrollView,
        ) {
            guard textView.string != updatedText else { return }
            let selectedRanges = textView.selectedRanges.map(\.rangeValue)
            let plan = LiveTranscriptEditorUpdatePolicy.plan(
                selectedRanges: selectedRanges,
                updatedText: updatedText,
                // The explicit follow/review state is authoritative. AppKit's
                // automatic first responder must not suppress the first ASR
                // append; real user interaction sets this Binding to false.
                isFollowing: isFollowing.wrappedValue,
            )
            let selectionAffinity = textView.selectionAffinity
            let preservedOrigin = scrollView.contentView.bounds.origin
            let oldText = textView.string
            let undoManager = textView.undoManager

            isApplyingExternalText = true
            undoManager?.disableUndoRegistration()
            if updatedText.hasPrefix(oldText), let textStorage = textView.textStorage {
                let suffix = String(updatedText.dropFirst(oldText.count))
                if !suffix.isEmpty {
                    textStorage.append(NSAttributedString(
                        string: suffix,
                        attributes: [
                            .font: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                            .foregroundColor: textView.textColor ?? NSColor.textColor,
                        ],
                    ))
                }
            } else {
                textView.string = updatedText
            }
            undoManager?.enableUndoRegistration()
            isApplyingExternalText = false
            textView.breakUndoCoalescing()

            textView.setSelectedRanges(
                plan.selections.map { NSValue(range: $0) },
                affinity: selectionAffinity,
                stillSelecting: false,
            )
            ensureLayout(of: textView)

            switch plan.viewportAction {
            case .preserveCurrentPosition:
                scrollView.contentView.scroll(to: preservedOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            case .followEnd:
                // Following changes only the viewport; a selection made before
                // focus was lost remains available when the user returns.
                scrollToEnd(in: textView)
            }
        }

        private func scrollToEnd(in textView: NSTextView) {
            ensureLayout(of: textView)
            textView.scrollRangeToVisible(
                NSRange(location: textView.string.utf16.count, length: 0),
            )
        }

        private func ensureLayout(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
        }

        private func publishHumanText(_ updatedText: String) {
            guard text.wrappedValue != updatedText else { return }
            text.wrappedValue = updatedText
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView else { return }
            // Never publish an intermediate IME/dead-key composition. Doing so
            // could make SwiftUI feed that partial text back and cancel it.
            guard !textView.hasMarkedText() else { return }

            var updatedText = textView.string
            if let pendingExternalText,
               let previousText = pendingExternalBaseText {
                pendingExternalBaseText = nil
                self.pendingExternalText = nil
                updatedText = LiveTranscriptEditorUpdatePolicy.mergingDeferredExternalText(
                    editorText: updatedText,
                    previousText: previousText,
                    updatedText: pendingExternalText,
                )
                if let scrollView = textView.enclosingScrollView {
                    applyExternalText(updatedText, in: textView, scrollView: scrollView)
                }
            }
            lastSynchronizedText = updatedText
            publishHumanText(updatedText)
        }
    }
}

@MainActor
/// Distinguishes AppKit's automatic initial first-responder assignment from a
/// person's intent to review or edit the transcript.
///
/// A newly inserted editable `NSTextView` can become first responder without
/// any user input. Treating that transition as editing would disable live
/// following before the first transcript arrives. Only that first automatic
/// transition is ignored; mouse, keyboard and accessibility selection actions
/// report review intent immediately, even if the view already owns focus.
final class FocusReportingTextView: NSTextView {
    var focusDidChange: ((Bool) -> Void)?
    var automaticFocusDidOccur: (() -> Void)?
    private var focusIntentGate = LiveTranscriptFocusIntentGate()

    private func reportReviewIntent() {
        if focusIntentGate.userExpressedReviewIntent() == .reviewBegan {
            focusDidChange?(true)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        guard becameFirstResponder else { return false }

        // Keyboard focus traversal is explicit even when this is the first
        // responder transition. Mouse intent is reported by `mouseDown` before
        // AppKit asks the text view to become first responder.
        let currentEvent = NSApp.currentEvent
        let arrivedThroughTab = LiveTranscriptFocusIntentGate.isKeyboardFocusTraversal(
            eventType: currentEvent?.type,
            keyCode: currentEvent?.keyCode,
        )
        switch focusIntentGate.responderBecame(
            // Do not treat Return/Space used to start the recording as editor
            // intent when AppKit inserts this view during the same event.
            explicitKeyboardIntent: arrivedThroughTab,
        ) {
        case .ignoredInitialAutomaticFocus:
            automaticFocusDidOccur?()
        case .reviewBegan:
            focusDidChange?(true)
        case .reviewEnded, nil:
            break
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder,
           focusIntentGate.responderResigned() == .reviewEnded {
            focusDidChange?(false)
        }
        return resignedFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        reportReviewIntent()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        reportReviewIntent()
        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        reportReviewIntent()
        super.keyDown(with: event)
    }

    override func selectAll(_ sender: Any?) {
        reportReviewIntent()
        super.selectAll(sender)
    }

    override func setAccessibilitySelectedTextRange(_ value: NSRange) {
        reportReviewIntent()
        super.setAccessibilitySelectedTextRange(value)
    }

    override func setAccessibilitySelectedTextRanges(_ value: [NSValue]?) {
        reportReviewIntent()
        super.setAccessibilitySelectedTextRanges(value)
    }
}
