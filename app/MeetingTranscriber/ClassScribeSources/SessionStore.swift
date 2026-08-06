import Foundation

struct SessionStore {
    let root: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassScribe/Classes", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func createFolder(subject: String, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let slug = subject.filenameSlug.isEmpty ? "Clase" : subject.filenameSlug
        let folder = root.appendingPathComponent("\(formatter.string(from: date))_\(slug)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    func saveLive(stable: String, provisional: String, folder: URL) throws {
        struct Snapshot: Codable { var stable: String; var provisional: String; var updatedAt: Date }
        try writeJSON(Snapshot(stable: stable, provisional: provisional, updatedAt: Date()), to: folder.appendingPathComponent("live-transcript.json"))
    }

    func saveFinal(
        metadata: ClassMetadata,
        all: [TranscriptSegment],
        professor: [TranscriptSegment],
        review: [ReviewItem],
        speakers: [SpeakerRecord],
        folder: URL
    ) throws {
        try writeJSON(metadata, to: folder.appendingPathComponent("metadata.json"))
        try writeJSON(all, to: folder.appendingPathComponent("all-speakers.json"))
        try writeJSON(review, to: folder.appendingPathComponent("review.json"))
        try writeJSON(speakers, to: folder.appendingPathComponent("speakers.json"))
        try TranscriptExporter.plainText(all).write(to: folder.appendingPathComponent("all-speakers.txt"), atomically: true, encoding: .utf8)
        try TranscriptExporter.plainText(professor).write(to: folder.appendingPathComponent("professor.txt"), atomically: true, encoding: .utf8)
        try TranscriptExporter.markdown(subject: metadata.subject, date: metadata.startedAt, segments: professor)
            .write(to: folder.appendingPathComponent("professor.md"), atomically: true, encoding: .utf8)
        try TranscriptExporter.srt(professor).write(to: folder.appendingPathComponent("professor.srt"), atomically: true, encoding: .utf8)
    }

    func saveVoiceReference(_ reference: ProfessorVoiceReference, folder: URL) throws {
        try writeJSON(reference, to: folder.appendingPathComponent("professor-voice-reference.json"))
        let voices = root.deletingLastPathComponent().appendingPathComponent("ProfessorVoices", isDirectory: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        let name = reference.subject.filenameSlug.isEmpty ? "Profesor" : reference.subject.filenameSlug
        try writeJSON(reference, to: voices.appendingPathComponent("\(name).json"))
    }

    func loadVoiceReference(subject: String) -> ProfessorVoiceReference? {
        let name = subject.filenameSlug.isEmpty ? "Profesor" : subject.filenameSlug
        let url = root.deletingLastPathComponent().appendingPathComponent("ProfessorVoices/\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ProfessorVoiceReference.self, from: data)
    }

    func history() -> [ClassMetadata] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders.compactMap { folder in
            let url = folder.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ClassMetadata.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
