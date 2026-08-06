import Foundation

public enum DiarizationIPC {
    public static let schemaVersion = 1
}

public struct DiarizationWorkerRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var jobID: UUID
    public var inputFilename: String
    public var outputFilename: String

    public init(
        schemaVersion: Int = DiarizationIPC.schemaVersion,
        jobID: UUID,
        inputFilename: String,
        outputFilename: String,
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.inputFilename = inputFilename
        self.outputFilename = outputFilename
    }
}

public struct DiarizationWorkerSpan: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speakerID: String
    public var quality: Double

    public init(start: TimeInterval, end: TimeInterval, speakerID: String, quality: Double) {
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.quality = quality
    }
}

public struct DiarizationWorkerFailure: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct DiarizationWorkerResponse: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var jobID: UUID
    public var spans: [DiarizationWorkerSpan]
    public var embeddings: [String: [Float]]
    public var failure: DiarizationWorkerFailure?

    public init(
        schemaVersion: Int = DiarizationIPC.schemaVersion,
        jobID: UUID,
        spans: [DiarizationWorkerSpan],
        embeddings: [String: [Float]],
        failure: DiarizationWorkerFailure? = nil,
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.spans = spans
        self.embeddings = embeddings
        self.failure = failure
    }
}
