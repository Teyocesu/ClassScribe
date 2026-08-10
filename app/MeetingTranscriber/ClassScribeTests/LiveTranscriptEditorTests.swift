@testable import ClassScribe
import AppKit
import Foundation
import SwiftUI
import Testing

@Test
func focusedEditorPreservesAnExactSelectionWhenASRAppends() {
    let selection = NSRange(location: 8, length: 5)

    let plan = LiveTranscriptEditorUpdatePolicy.plan(
        selectedRange: selection,
        updatedText: "Texto corregido y nuevo contenido automático",
        isFollowing: false,
    )

    #expect(plan.selection == selection)
    #expect(plan.viewportAction == .preserveCurrentPosition)
}

@Test
func unfocusedEditorFollowsTheNewestTranscript() {
    let plan = LiveTranscriptEditorUpdatePolicy.plan(
        selectedRange: NSRange(location: 3, length: 0),
        updatedText: "Texto con una ventana nueva",
        isFollowing: true,
    )

    #expect(plan.selection == NSRange(location: 3, length: 0))
    #expect(plan.viewportAction == .followEnd)
}

@Test
func selectionIsClampedSafelyWhenExternalTextShrinks() {
    #expect(LiveTranscriptEditorUpdatePolicy.clampedSelection(
        NSRange(location: 8, length: 9),
        utf16Length: 12,
    ) == NSRange(location: 8, length: 4))
    #expect(LiveTranscriptEditorUpdatePolicy.clampedSelection(
        NSRange(location: 20, length: 4),
        utf16Length: 12,
    ) == NSRange(location: 12, length: 0))
    #expect(LiveTranscriptEditorUpdatePolicy.clampedSelection(
        NSRange(location: NSNotFound, length: 0),
        utf16Length: 12,
    ) == NSRange(location: 12, length: 0))
}

@Test
func selectionUsesNSTextViewsUTF16CoordinateSpace() {
    let text = "A🧑🏽‍🏫B"
    let utf16End = text.utf16.count

    let plan = LiveTranscriptEditorUpdatePolicy.plan(
        selectedRange: NSRange(location: utf16End + 10, length: 3),
        updatedText: text,
        isFollowing: false,
    )

    #expect(plan.selection == NSRange(location: utf16End, length: 0))
    #expect(plan.viewportAction == .preserveCurrentPosition)
}

@Test
func emptyExternalTextProducesAValidCaret() {
    let plan = LiveTranscriptEditorUpdatePolicy.plan(
        selectedRange: NSRange(location: 4, length: 2),
        updatedText: "",
        isFollowing: true,
    )

    #expect(plan.selection == NSRange(location: 0, length: 0))
    #expect(plan.viewportAction == .followEnd)
}

@Test
func allSelectionsArePreservedAndClampedIndependently() {
    let plan = LiveTranscriptEditorUpdatePolicy.plan(
        selectedRanges: [
            NSRange(location: 2, length: 3),
            NSRange(location: 9, length: 8),
            NSRange(location: 40, length: 0),
        ],
        updatedText: "doce caracteres",
        isFollowing: false,
    )

    #expect(plan.selections == [
        NSRange(location: 2, length: 3),
        NSRange(location: 9, length: 6),
        NSRange(location: 15, length: 0),
    ])
    #expect(plan.viewportAction == .preserveCurrentPosition)
}

@Test
func emptySelectionCollectionGetsAValidCaretAtTheEnd() {
    let text = "Texto"
    let plan = LiveTranscriptEditorUpdatePolicy.plan(
        selectedRanges: [],
        updatedText: text,
        isFollowing: false,
    )

    #expect(plan.selections == [NSRange(location: text.utf16.count, length: 0)])
}

@Test
func deferredIMEUpdateKeepsCompositionAndAddsOnlyExternalSuffix() {
    let merged = LiveTranscriptEditorUpdatePolicy.mergingDeferredExternalText(
        editorText: "La explicación dice veintidós",
        previousText: "La explicacion dice veinte",
        updatedText: "La explicacion dice veinte y continúa la clase",
    )

    #expect(merged == "La explicación dice veintidós y continúa la clase")
}

@Test
func nonAppendDeferredUpdateNeverOverwritesComposedText() {
    let composed = "Corrección con acento: función"
    let merged = LiveTranscriptEditorUpdatePolicy.mergingDeferredExternalText(
        editorText: composed,
        previousText: "hipótesis anterior",
        updatedText: "reemplazo incompatible",
    )

    #expect(merged == composed)
}

@Test
func deferredFirstASRWindowIsSeparatedFromAnIMEHumanNote() {
    let merged = LiveTranscriptEditorUpdatePolicy.mergingDeferredExternalText(
        editorText: "Nota humana",
        previousText: "",
        updatedText: "Primera frase de la clase",
    )

    #expect(merged == "Nota humana Primera frase de la clase")
}

@MainActor
@Test
func finalizationCommitsMarkedTextMergesPendingASRAndPublishesBeforeCallback() throws {
    let box = LiveEditorBindingBox(text: "", isFollowing: false)
    var persistedText: String?
    var callbackCount = 0
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
        onFinalize: {
            persistedText = box.text
            callbackCount += 1
        },
    )
    let (scrollView, textView) = makeScrollableEditor(text: "")
    textView.delegate = coordinator
    coordinator.setEditing(true)
    textView.setMarkedText(
        "Nota humana",
        selectedRange: NSRange(location: 11, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0),
    )
    #expect(textView.hasMarkedText())

    box.text = "Primera frase de la clase"
    coordinator.receiveExternalText(box.text, in: textView, scrollView: scrollView)
    #expect(textView.string == "Nota humana")

    let finalized = coordinator.finalizeEditing(in: textView, scrollView: scrollView)

    #expect(!textView.hasMarkedText())
    #expect(finalized == "Nota humana Primera frase de la clase")
    #expect(textView.string == finalized)
    #expect(box.text == finalized)
    #expect(persistedText == finalized)
    #expect(callbackCount == 1)
    #expect(!box.isEditing)
}

@MainActor
@Test
func finalizationMergesLatestBindingWhenDismantledBeforeUpdateNSView() {
    let base = "Texto base"
    let box = LiveEditorBindingBox(text: base, isFollowing: false)
    var persistedText: String?
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
        onFinalize: { persistedText = box.text },
    )
    let (scrollView, textView) = makeScrollableEditor(text: base)
    textView.delegate = coordinator
    textView.setSelectedRange(NSRange(location: base.utf16.count, length: 0))
    textView.setMarkedText(
        " nota humana",
        selectedRange: NSRange(location: 12, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0),
    )
    #expect(textView.hasMarkedText())

    // Simulate SwiftUI replacing the Binding immediately before dismantling;
    // deliberately do not call `receiveExternalText`/`updateNSView`.
    box.text = base + " sufijo ASR"
    let finalized = coordinator.finalizeEditing(in: textView, scrollView: scrollView)

    #expect(finalized == "Texto base nota humana sufijo ASR")
    #expect(textView.string == finalized)
    #expect(box.text == finalized)
    #expect(persistedText == finalized)
    #expect(!textView.hasMarkedText())
}

@MainActor
@Test
func appKitEditorPreservesCaretAndViewportWhileReviewing() {
    let original = (0 ..< 120).map { "Línea \($0): explicación de prueba" }.joined(separator: "\n")
    let box = LiveEditorBindingBox(text: original, isFollowing: false)
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
    )
    let (scrollView, textView) = makeScrollableEditor(text: original)
    let selection = NSRange(location: 18, length: 7)
    textView.setSelectedRange(selection)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 420))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let viewport = scrollView.contentView.bounds.origin

    let updated = original + "\nNueva oración transcripta al final."
    box.text = updated
    coordinator.receiveExternalText(updated, in: textView, scrollView: scrollView)

    #expect(textView.string == updated)
    #expect(textView.selectedRange() == selection)
    #expect(scrollView.contentView.bounds.origin == viewport)
}

@MainActor
@Test
func appKitEditorFollowsTheEndWithoutMovingItsStoredSelection() {
    let original = (0 ..< 120).map { "Línea \($0): contenido" }.joined(separator: "\n")
    let box = LiveEditorBindingBox(text: original, isFollowing: true)
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
    )
    let (scrollView, textView) = makeScrollableEditor(text: original)
    let storedSelection = NSRange(location: 5, length: 0)
    textView.setSelectedRange(storedSelection)
    scrollView.contentView.scroll(to: .zero)

    let updated = original + "\nLa frase más reciente debe quedar visible."
    box.text = updated
    coordinator.receiveExternalText(updated, in: textView, scrollView: scrollView)

    #expect(textView.selectedRange() == storedSelection)
    #expect(scrollView.contentView.bounds.origin.y > 0)
}

@MainActor
@Test
func focusPausesFollowingAndBlurDoesNotResumeItUnexpectedly() {
    let box = LiveEditorBindingBox(text: "Texto", isFollowing: true)
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
    )

    coordinator.setEditing(true)
    #expect(box.isEditing)
    #expect(!box.isFollowing)

    coordinator.setEditing(false)
    #expect(!box.isEditing)
    #expect(!box.isFollowing)
}

@MainActor
@Test
func explicitFollowRequestScrollsImmediatelyWithoutWaitingForMoreASR() {
    let text = (0 ..< 120).map { "Línea \($0)" }.joined(separator: "\n")
    let box = LiveEditorBindingBox(text: text, isFollowing: false)
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
    )
    let (scrollView, textView) = makeScrollableEditor(text: text)
    scrollView.contentView.scroll(to: .zero)

    box.isFollowing = true
    coordinator.synchronizeFollowing(in: textView)

    #expect(scrollView.contentView.bounds.origin.y > 0)
}

@MainActor
@Test
func humanLiveScrollPausesAutomaticFollowing() {
    let box = LiveEditorBindingBox(text: "Texto", isFollowing: true)
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
    )
    let scrollView = NSScrollView()
    coordinator.observeUserScrolling(in: scrollView)
    defer { coordinator.stopObservingUserScrolling() }

    NotificationCenter.default.post(
        name: NSScrollView.willStartLiveScrollNotification,
        object: scrollView,
    )

    #expect(!box.isFollowing)
}

@Test
func initialAutomaticFocusIsIgnoredUntilAUserExpressesReviewIntent() {
    var gate = LiveTranscriptFocusIntentGate()

    #expect(gate.responderBecame(explicitKeyboardIntent: false)
        == .ignoredInitialAutomaticFocus)
    #expect(gate.userExpressedReviewIntent() == .reviewBegan)
    #expect(gate.userExpressedReviewIntent() == nil)
    #expect(gate.responderResigned() == .reviewEnded)
}

@Test
func keyboardTraversalOnTheFirstFocusCountsAsReviewIntent() {
    var gate = LiveTranscriptFocusIntentGate()

    #expect(gate.responderBecame(explicitKeyboardIntent: true) == .reviewBegan)
    #expect(gate.responderResigned() == .reviewEnded)
}

@Test
func onlyTabMakesTheInitialFocusAnExplicitKeyboardTraversal() {
    #expect(LiveTranscriptFocusIntentGate.isKeyboardFocusTraversal(
        eventType: .keyDown,
        keyCode: 48,
    ))
    #expect(!LiveTranscriptFocusIntentGate.isKeyboardFocusTraversal(
        eventType: .keyDown,
        keyCode: 36, // Return can be the event that started recording.
    ))
    #expect(!LiveTranscriptFocusIntentGate.isKeyboardFocusTraversal(
        eventType: .leftMouseDown,
        keyCode: nil,
    ))
}

@Test
func onlyTheFirstAutomaticFocusIsIgnored() {
    var gate = LiveTranscriptFocusIntentGate()

    #expect(gate.responderBecame(explicitKeyboardIntent: false)
        == .ignoredInitialAutomaticFocus)
    #expect(gate.responderResigned() == nil)
    #expect(gate.responderBecame(explicitKeyboardIntent: false) == .reviewBegan)
}

@MainActor
@Test
func ignoredAutomaticFocusAlignsExistingTranscriptToTheEnd() async {
    let text = (0 ..< 120).map { "Línea \($0)" }.joined(separator: "\n")
    let box = LiveEditorBindingBox(text: text, isFollowing: true)
    let coordinator = LiveTranscriptEditor.Coordinator(
        text: box.textBinding,
        isEditing: box.editingBinding,
        isFollowing: box.followingBinding,
    )
    let (scrollView, textView) = makeScrollableEditor(text: text)
    scrollView.contentView.scroll(to: .zero)

    coordinator.handleAutomaticFocus(in: textView)
    for _ in 0 ..< 5 { await Task.yield() }

    #expect(!box.isEditing)
    #expect(box.isFollowing)
    #expect(scrollView.contentView.bounds.origin.y > 0)
}

@MainActor
private final class LiveEditorBindingBox {
    var text: String
    var isEditing = false
    var isFollowing: Bool

    init(text: String, isFollowing: Bool) {
        self.text = text
        self.isFollowing = isFollowing
    }

    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }

    var editingBinding: Binding<Bool> {
        Binding(get: { self.isEditing }, set: { self.isEditing = $0 })
    }

    var followingBinding: Binding<Bool> {
        Binding(get: { self.isFollowing }, set: { self.isFollowing = $0 })
    }
}

@MainActor
private func makeScrollableEditor(text: String) -> (NSScrollView, NSTextView) {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
    scrollView.hasVerticalScroller = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 3_600))
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
        width: scrollView.contentSize.width,
        height: CGFloat.greatestFiniteMagnitude,
    )
    textView.string = text
    scrollView.documentView = textView
    if let layoutManager = textView.layoutManager,
       let textContainer = textView.textContainer {
        layoutManager.ensureLayout(for: textContainer)
    }
    return (scrollView, textView)
}
