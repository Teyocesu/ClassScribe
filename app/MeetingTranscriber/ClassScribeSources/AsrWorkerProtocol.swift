import Foundation

enum AsrWorkerProtocol {
    static let supportedVersion = 1
    static let maximumMessageBytes = 1_048_576
}

enum AsrWorkerProtocolSerializationError: Error, Equatable {
    case messageTooLarge
}

enum AsrWorkerMessageType: String, Codable, Equatable, Sendable {
    case hello
    case ready
    case heartbeat
    case progress
    case start
    case result
    case recoverableError
    case terminalError
    case cancel
    case cancelled
    case shutdown
}

enum AsrWorkerProtocolValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidProtocolVersion
    case invalidIdentity
    case malformedPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidProtocolVersion:
            return "La versión del protocolo ASR no es válida."
        case .invalidIdentity:
            return "El mensaje ASR no tiene identidad de intento o job válida."
        case let .malformedPayload(message):
            return "El payload del protocolo ASR es inválido: \(message)"
        }
    }
}

struct AsrWorkerEnvelope: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var attemptID: SessionAttemptID
    var jobID: UUID
    var messageType: AsrWorkerMessageType
    var supportedVersions: [Int]?
    var selectedVersion: Int?
    var sourceReference: String?
    var progress: Double?
    var text: String?
    var code: String?
    var message: String?

    init(
        protocolVersion: Int = AsrWorkerProtocol.supportedVersion,
        attemptID: SessionAttemptID,
        jobID: UUID,
        messageType: AsrWorkerMessageType,
        supportedVersions: [Int]? = nil,
        selectedVersion: Int? = nil,
        sourceReference: String? = nil,
        progress: Double? = nil,
        text: String? = nil,
        code: String? = nil,
        message: String? = nil,
    ) {
        self.protocolVersion = protocolVersion
        self.attemptID = attemptID
        self.jobID = jobID
        self.messageType = messageType
        self.supportedVersions = supportedVersions
        self.selectedVersion = selectedVersion
        self.sourceReference = sourceReference
        self.progress = progress
        self.text = text
        self.code = code
        self.message = message
    }

    static func hello(attemptID: SessionAttemptID, jobID: UUID) -> Self {
        Self(
            attemptID: attemptID,
            jobID: jobID,
            messageType: .hello,
            supportedVersions: [AsrWorkerProtocol.supportedVersion],
        )
    }

    static func ready(
        attemptID: SessionAttemptID,
        jobID: UUID,
        protocolVersion: Int = AsrWorkerProtocol.supportedVersion,
        selectedVersion: Int = AsrWorkerProtocol.supportedVersion,
    ) -> Self {
        Self(
            protocolVersion: protocolVersion,
            attemptID: attemptID,
            jobID: jobID,
            messageType: .ready,
            selectedVersion: selectedVersion,
        )
    }

    static func heartbeat(attemptID: SessionAttemptID, jobID: UUID) -> Self {
        Self(attemptID: attemptID, jobID: jobID, messageType: .heartbeat)
    }

    static func progress(
        attemptID: SessionAttemptID,
        jobID: UUID,
        fraction: Double,
    ) -> Self {
        Self(
            attemptID: attemptID,
            jobID: jobID,
            messageType: .progress,
            progress: fraction,
        )
    }

    static func start(
        attemptID: SessionAttemptID,
        jobID: UUID,
        sourceReference: String? = nil,
    ) -> Self {
        Self(
            attemptID: attemptID,
            jobID: jobID,
            messageType: .start,
            sourceReference: sourceReference,
        )
    }

    static func result(
        attemptID: SessionAttemptID,
        jobID: UUID,
        text: String?,
    ) -> Self {
        Self(
            attemptID: attemptID,
            jobID: jobID,
            messageType: .result,
            text: text,
        )
    }

    static func error(
        attemptID: SessionAttemptID,
        jobID: UUID,
        recoverable: Bool,
        code: String,
        message: String,
    ) -> Self {
        Self(
            attemptID: attemptID,
            jobID: jobID,
            messageType: recoverable ? .recoverableError : .terminalError,
            code: code,
            message: message,
        )
    }

    func validateShape() throws {
        guard protocolVersion > 0 else {
            throw AsrWorkerProtocolValidationError.invalidProtocolVersion
        }
        let zeroUUID = "00000000-0000-0000-0000-000000000000"
        guard attemptID.generation > 0,
              attemptID.sessionID.uuidString.lowercased() != zeroUUID,
              attemptID.nonce.uuidString.lowercased() != zeroUUID,
              jobID.uuidString.lowercased() != zeroUUID
        else {
            throw AsrWorkerProtocolValidationError.invalidIdentity
        }

        switch messageType {
        case .hello:
            guard let supportedVersions,
                  !supportedVersions.isEmpty,
                  supportedVersions.allSatisfy({ $0 > 0 })
            else {
                throw AsrWorkerProtocolValidationError.malformedPayload("hello sin versiones soportadas")
            }
        case .ready:
            guard let selectedVersion, selectedVersion > 0 else {
                throw AsrWorkerProtocolValidationError.malformedPayload("ready sin versión seleccionada")
            }
        case .progress:
            guard let progress, progress.isFinite, (0 ... 1).contains(progress) else {
                throw AsrWorkerProtocolValidationError.malformedPayload("progreso fuera de rango")
            }
        case .result:
            guard text != nil else {
                throw AsrWorkerProtocolValidationError.malformedPayload("result sin texto")
            }
        case .recoverableError, .terminalError:
            guard let code, !code.isEmpty, let message, !message.isEmpty else {
                throw AsrWorkerProtocolValidationError.malformedPayload("error sin código o mensaje")
            }
        case .heartbeat, .start, .cancel, .cancelled, .shutdown:
            break
        }
    }

    func encodedData() throws -> Data {
        try validateShape()
        let data = try JSONEncoder().encode(self)
        guard data.count <= AsrWorkerProtocol.maximumMessageBytes else {
            throw AsrWorkerProtocolSerializationError.messageTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= AsrWorkerProtocol.maximumMessageBytes else {
            throw AsrWorkerProtocolSerializationError.messageTooLarge
        }
        let message = try JSONDecoder().decode(Self.self, from: data)
        try message.validateShape()
        return message
    }
}

enum AsrWorkerExit: Equatable, Sendable {
    case clean(Int32)
    case crashed(Int32)
}

enum AsrWorkerTransportFault: Error, Equatable, Sendable {
    case launchFailed(String)
    case malformedFrame(String)
    case oversizedFrame
    case unexpectedEOF
    case readFailed(String)
    case writeFailed(String)

    var message: String {
        switch self {
        case let .launchFailed(message), let .malformedFrame(message), let .readFailed(message), let .writeFailed(message):
            message
        case .oversizedFrame:
            "El frame ASR excede el límite de tamaño."
        case .unexpectedEOF:
            "El transporte ASR terminó antes de completar un frame."
        }
    }
}

protocol AsrWorkerTransport: AnyObject {
    var onMessage: ((AsrWorkerEnvelope) -> Void)? { get set }
    var onExit: ((AsrWorkerExit) -> Void)? { get set }
    var onFault: ((AsrWorkerTransportFault) -> Void)? { get set }
    var isTerminated: Bool { get }

    /// `start` and `send` must return without waiting for a worker write or
    /// process completion. `terminate` is independent from that write path.
    func start(with hello: AsrWorkerEnvelope)
    func send(_ message: AsrWorkerEnvelope)
    func terminate()
}
