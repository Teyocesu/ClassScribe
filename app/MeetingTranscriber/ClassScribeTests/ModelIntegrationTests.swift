import Foundation
import Testing
@testable import ClassScribe

@Test(
    "Parakeet transcribe un fixture conocido en español",
    .enabled(if: ProcessInfo.processInfo.environment["CLASSSCRIBE_RUN_MODEL_TESTS"] == "1")
)
func spanishModelFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["CLASSSCRIBE_TEST_AUDIO"] else {
        Issue.record("Falta CLASSSCRIBE_TEST_AUDIO")
        return
    }
    let service = ParakeetService()
    let segments = try await service.transcribe(file: URL(fileURLWithPath: path))
    let text = segments.map(\.text).joined(separator: " ").lowercased()
    #expect(!text.isEmpty)
    #expect(text.contains("método") || text.contains("ecuaciones"))
    let words = text.split(separator: " ")
    #expect(words.count > 5)
}

@Test(
    "FluidAudio detecta al menos dos voces en el fixture sintético",
    .enabled(if: ProcessInfo.processInfo.environment["CLASSSCRIBE_RUN_DIARIZATION_TESTS"] == "1")
)
func twoSpeakerFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["CLASSSCRIBE_TWO_SPEAKER_AUDIO"] else {
        Issue.record("Falta CLASSSCRIBE_TWO_SPEAKER_AUDIO")
        return
    }
    let service = ParakeetService()
    let processor = FinalProcessor(parakeet: service)
    let result = try await processor.diarize(URL(fileURLWithPath: path))
    #expect(Set(result.spans.map(\.speakerID)).count >= 2)
}
