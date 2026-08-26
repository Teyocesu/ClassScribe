import Foundation

public struct AudioManifestMaster: Codable, Equatable, Sendable {
    public var relativePath: String
    public var encoding: String
    public var sampleRate: Int
    public var channels: Int

    public init(
        relativePath: String = "master.raw",
        encoding: String = "float32LE",
        sampleRate: Int,
        channels: Int,
    ) {
        self.relativePath = relativePath
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct AudioManifestASRDerivative: Codable, Equatable, Sendable {
    public var relativePath: String
    public var encoding: String
    public var sampleRate: Int
    public var channels: Int

    public init(
        relativePath: String = "source.wav",
        encoding: String = "float32LE",
        sampleRate: Int = 16000,
        channels: Int = 1,
    ) {
        self.relativePath = relativePath
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct AudioManifestConversion: Codable, Equatable, Sendable {
    public var sourceGeneration: UInt64
    public var inputSampleRate: Int
    public var inputChannels: Int
    public var outputSampleRate: Int
    public var outputChannels: Int

    public init(
        sourceGeneration: UInt64,
        inputSampleRate: Int,
        inputChannels: Int,
        outputSampleRate: Int,
        outputChannels: Int,
    ) {
        self.sourceGeneration = sourceGeneration
        self.inputSampleRate = inputSampleRate
        self.inputChannels = inputChannels
        self.outputSampleRate = outputSampleRate
        self.outputChannels = outputChannels
    }
}

public struct AudioManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var master: AudioManifestMaster
    public var asrDerivative: AudioManifestASRDerivative
    public var conversions: [AudioManifestConversion]

    public init(
        version: Int = 1,
        master: AudioManifestMaster,
        asrDerivative: AudioManifestASRDerivative = AudioManifestASRDerivative(),
        conversions: [AudioManifestConversion] = [],
    ) {
        self.version = version
        self.master = master
        self.asrDerivative = asrDerivative
        self.conversions = conversions
    }
}

public enum AudioManifestError: LocalizedError, Sendable {
    case invalidVersion
    case unsafePath
    case invalidFormat
    case invalidFile

    public var errorDescription: String? {
        switch self {
        case .invalidVersion: "Unsupported audio manifest version."
        case .unsafePath: "The audio manifest contains an unsafe relative path."
        case .invalidFormat: "The audio manifest contains an unsupported format."
        case .invalidFile: "The audio manifest or master is not a regular file."
        }
    }
}

public enum AudioManifestStore {
    public static func read(from url: URL) throws -> AudioManifest {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 1_048_576
        else { throw AudioManifestError.invalidFile }
        let manifest = try JSONDecoder().decode(AudioManifest.self, from: Data(contentsOf: url))
        try validate(manifest)
        return manifest
    }

    public static func validate(_ manifest: AudioManifest) throws {
        guard manifest.version == 1 else { throw AudioManifestError.invalidVersion }
        guard isSafeRelativePath(manifest.master.relativePath),
              isSafeRelativePath(manifest.asrDerivative.relativePath),
              manifest.master.relativePath == "master.raw",
              manifest.asrDerivative.relativePath == "source.wav"
        else { throw AudioManifestError.unsafePath }
        guard manifest.master.encoding == "float32LE",
              manifest.master.sampleRate > 0,
              (1 ... 2).contains(manifest.master.channels),
              manifest.asrDerivative.encoding == "float32LE",
              manifest.asrDerivative.sampleRate == 16000,
              manifest.asrDerivative.channels == 1
        else { throw AudioManifestError.invalidFormat }
        for conversion in manifest.conversions {
            guard conversion.sourceGeneration > 0,
                  conversion.inputSampleRate > 0,
                  conversion.inputChannels > 0,
                  conversion.outputSampleRate == manifest.master.sampleRate,
                  conversion.outputChannels == manifest.master.channels
            else { throw AudioManifestError.invalidFormat }
        }
    }

    public static func write(_ manifest: AudioManifest, to url: URL) throws {
        try validate(manifest)
        let directory = url.deletingLastPathComponent()
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw AudioManifestError.invalidFile
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        if FileManager.default.fileExists(atPath: url.path) {
            let fileValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else {
                throw AudioManifestError.invalidFile
            }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func resolve(_ relativePath: String, from manifestURL: URL) throws -> URL {
        guard isSafeRelativePath(relativePath) else { throw AudioManifestError.unsafePath }
        return manifestURL.deletingLastPathComponent().appendingPathComponent(relativePath)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.contains("/")
            && !path.contains("\\")
            && path != "."
            && path != ".."
            && URL(fileURLWithPath: path).lastPathComponent == path
    }
}
