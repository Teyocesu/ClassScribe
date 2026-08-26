import Darwin
import Foundation

/// Writes the source-rate Float32 master and owns the immutable format choice
/// for one online capture attempt. It is driven from the capture's serial
/// write queue, including across CATap generations.
@available(macOS 14.2, *)
public final class MasterAudioWriter: @unchecked Sendable {
    private let outputFileDescriptor: Int32
    private let failureLock = NSLock()
    public let masterURL: URL
    public let manifestURL: URL
    public let timelineAnchor: TimelineAnchor
    private(set) public var format: AudioManifestMaster?
    private(set) public var manifest: AudioManifest?
    private(set) public var framesWritten: Int64 = 0
    private(set) public var frameClock: MasterFrameClock?
    private var storedFailure: CaptureNativeTerminalFailure?
    private var converter: StreamingMasterResampler?
    private var converterKey: ConverterKey?
    private var converterSourceFrameStart: Int64 = 0
    private var converterTargetFrames: Int64 = 0

    /// Compatibility projection retained for existing capture and validation
    /// callers. The category-bearing value is `terminalFailure`.
    public var failureMessage: String? {
        terminalFailure?.message
    }

    public var terminalFailure: CaptureNativeTerminalFailure? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return storedFailure
    }

    public init(
        outputFileDescriptor: Int32,
        masterURL: URL,
        manifestURL: URL,
        timelineAnchor: TimelineAnchor? = nil,
    ) {
        self.outputFileDescriptor = outputFileDescriptor
        self.masterURL = masterURL
        self.manifestURL = manifestURL
        self.timelineAnchor = timelineAnchor ?? TimelineAnchor()
    }

    public var duration: TimeInterval {
        guard let format, format.sampleRate > 0 else { return 0 }
        return Double(framesWritten) / Double(format.sampleRate)
    }

    /// Accepts one interleaved Float32 callback. Empty callbacks do not select
    /// a format. The manifest is persisted before this method writes the first
    /// master byte.
    @discardableResult
    public func append(
        _ samples: [Float],
        inputRate: Int,
        inputChannels: Int,
        hostTicks: UInt64,
        sourceGeneration: UInt64,
    ) throws -> Bool {
        if let terminalFailure {
            throw Self.terminalError(terminalFailure.message)
        }
        guard !samples.isEmpty, inputRate > 0, inputChannels > 0 else { return false }
        do {
            return try appendImpl(
                samples,
                inputRate: inputRate,
                inputChannels: inputChannels,
                hostTicks: hostTicks,
                sourceGeneration: sourceGeneration,
            )
        } catch {
            recordFailure(error)
            throw error
        }
    }

    /// Drains the pending look-ahead frame for the current source format. The
    /// returned tail is written before a new generation's timeline gap, so a
    /// format handoff never interpolates through silence.
    public func finish() throws {
        if let terminalFailure {
            throw Self.terminalError(terminalFailure.message)
        }
        do {
            try flushConverter()
        } catch {
            recordFailure(error)
            throw error
        }
    }

    private func appendImpl(
        _ samples: [Float],
        inputRate: Int,
        inputChannels: Int,
        hostTicks: UInt64,
        sourceGeneration: UInt64,
    ) throws -> Bool {
        let frameCount = samples.count / inputChannels
        guard frameCount > 0 else { return false }
        let complete = Array(samples.prefix(frameCount * inputChannels))
        let outputChannels = min(inputChannels, 2)
        let selected = format ?? AudioManifestMaster(
            sampleRate: inputRate,
            channels: outputChannels,
        )
        let needsConversion = inputRate != selected.sampleRate || inputChannels != selected.channels

        if format == nil {
            var conversions: [AudioManifestConversion] = []
            if needsConversion {
                conversions.append(AudioManifestConversion(
                    sourceGeneration: max(1, sourceGeneration),
                    inputSampleRate: inputRate,
                    inputChannels: inputChannels,
                    outputSampleRate: selected.sampleRate,
                    outputChannels: selected.channels,
                ))
            }
            let candidateManifest = AudioManifest(
                master: selected,
                conversions: conversions,
            )
            try AudioManifestStore.write(candidateManifest, to: manifestURL)
            format = selected
            manifest = candidateManifest
            guard let clock = MasterFrameClock(masterRate: selected.sampleRate) else {
                throw NSError(
                    domain: "audiotap.master",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "El formato master no tiene una frecuencia válida."],
                )
            }
            frameClock = clock
            timelineAnchor.setRateIfUnanchored(selected.sampleRate)
        } else if needsConversion,
                  let current = manifest,
                  !current.conversions.contains(where: {
                      $0.sourceGeneration == max(1, sourceGeneration)
                          && $0.inputSampleRate == inputRate
                          && $0.inputChannels == inputChannels
                  }) {
            let conversion = AudioManifestConversion(
                sourceGeneration: max(1, sourceGeneration),
                inputSampleRate: inputRate,
                inputChannels: inputChannels,
                outputSampleRate: selected.sampleRate,
                outputChannels: selected.channels,
            )
            let updated = AudioManifest(
                master: selected,
                conversions: current.conversions + [conversion],
            )
            try AudioManifestStore.write(updated, to: manifestURL)
            manifest = updated
        }

        let key = ConverterKey(
            sourceGeneration: max(1, sourceGeneration),
            inputRate: inputRate,
            inputChannels: inputChannels,
        )
        if converterKey != key {
            try flushConverter()
            guard let newConverter = StreamingMasterResampler(
                inputRate: inputRate,
                inputChannels: inputChannels,
                outputRate: selected.sampleRate,
                outputChannels: selected.channels,
            ) else {
                throw NSError(
                    domain: "audiotap.master",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No se pudo crear el conversor master."],
                )
            }
            converter = newConverter
            converterKey = key
            converterSourceFrameStart = frameClock?.targetSourceFrames ?? 0
            converterTargetFrames = 0
        }

        guard let converter, let frameClock else { return false }
        let budget = frameClock.reserveSourceFrames(
            inputFrameCount: frameCount,
            inputRate: inputRate,
        )
        converterTargetFrames = budget.endFrame - converterSourceFrameStart
        let converted = converter.process(
            complete,
            targetOutputFrames: converterTargetFrames,
        )
        let logicalFrameCount = Int(budget.frameCount)
        let silenceFrames = timelineAnchor.silenceFramesBefore(
            hostSeconds: machTicksToSeconds(hostTicks),
            logicalFrameCount: logicalFrameCount,
        )
        if silenceFrames > 0 {
            try write(Self.float32LEData(
                repeating: 0,
                count: silenceFrames * selected.channels,
            ))
            framesWritten += Int64(silenceFrames)
        }
        if !converted.isEmpty {
            try write(Self.float32LEData(converted))
            framesWritten += Int64(converted.count / selected.channels)
        }
        return silenceFrames > 0 || !converted.isEmpty
    }

    /// Whether the next callback belongs to a source stream whose converter
    /// state cannot be reused. The Windows product uses the same distinction
    /// to drain the old packet before it plans the new handoff gap.
    public func requiresConverterReset(
        inputRate: Int,
        inputChannels: Int,
        sourceGeneration: UInt64,
    ) -> Bool {
        guard converter != nil else { return false }
        return converterKey != ConverterKey(
            sourceGeneration: max(1, sourceGeneration),
            inputRate: inputRate,
            inputChannels: inputChannels,
        )
    }

    public func validateManifest() throws {
        guard let manifest else { throw AudioManifestError.invalidFormat }
        try AudioManifestStore.validate(manifest)
    }

    /// Records a durable-path failure for the owner to surface during stop or
    /// recovery while allowing the independent live ASR branch to continue.
    public func recordFailure(_ error: Error) {
        failureLock.lock()
        if storedFailure == nil {
            storedFailure = CaptureNativeTerminalFailure(
                message: error.localizedDescription,
                category: .durableMaster,
            )
        }
        failureLock.unlock()
    }

    private func flushConverter() throws {
        guard let converter else { return }
        self.converter = nil
        converterKey = nil
        let tail = converter.finish(targetOutputFrames: converterTargetFrames)
        converterSourceFrameStart = frameClock?.targetSourceFrames ?? converterSourceFrameStart
        converterTargetFrames = 0
        guard !tail.isEmpty, let format else { return }
        let outputFrames = tail.count / format.channels
        try write(Self.float32LEData(tail))
        framesWritten += Int64(outputFrames)
    }

    private func write(_ data: Data) throws {
        guard outputFileDescriptor >= 0 else { throw POSIXError(.EBADF) }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    outputFileDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
    }

    fileprivate static func float32LEData(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            var bits = (sample.isFinite ? sample : 0).bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: MemoryLayout<UInt32>.size))
        }
        return data
    }

    private static func float32LEData(repeating value: Float, count: Int) -> Data {
        float32LEData([Float](repeating: value, count: count))
    }

    private static func terminalError(_ message: String) -> NSError {
        NSError(
            domain: "audiotap.master",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message],
        )
    }

    private struct ConverterKey: Equatable {
        let sourceGeneration: UInt64
        let inputRate: Int
        let inputChannels: Int
    }
}

/// Converts a validated master stream to the fixed Float32 mono raw stream
/// consumed by the app's existing WAV materializer.
@available(macOS 14.2, *)
public enum MasterAudioDerivative {
    @discardableResult
    public static func writeFloat32Raw(
        masterURL: URL,
        manifestURL: URL,
        destinationURL: URL,
    ) throws -> TimeInterval {
        let manifest = try AudioManifestStore.read(from: manifestURL)
        let declaredMaster = try AudioManifestStore.resolve(manifest.master.relativePath, from: manifestURL)
        let actualMaster = masterURL.standardizedFileURL
        guard declaredMaster.standardizedFileURL == actualMaster else {
            throw AudioManifestError.unsafePath
        }
        let values = try masterURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let bytesPerFrame = manifest.master.channels * MemoryLayout<Float>.size
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size % bytesPerFrame == 0
        else { throw AudioManifestError.invalidFile }
        let inputFrames = Int64(size / bytesPerFrame)
        let outputFrames = max(
            1,
            Int64((Double(inputFrames) * 16000 / Double(manifest.master.sampleRate)).rounded()),
        )

        let fileManager = FileManager.default
        let destinationValues = try? destinationURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard destinationValues?.isSymbolicLink != true else { throw AudioManifestError.invalidFile }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        ) else { throw AudioManifestError.invalidFile }

        let input = try FileHandle(forReadingFrom: masterURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }
        var carry = Data()
        var inputFramesRead: Int64 = 0
        var outputFramesWritten: Int64 = 0
        var previousFrame: Float = 0
        var hasPreviousFrame = false
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            var combined = carry
            combined.append(chunk)
            let completeLength = combined.count - (combined.count % bytesPerFrame)
            if completeLength > 0 {
                let masterSamples = Self.decodeMasterMono(
                    combined.prefix(completeLength),
                    channels: manifest.master.channels,
                )
                let blockStart = inputFramesRead
                let blockEnd = blockStart + Int64(masterSamples.count)
                var derivativeSamples: [Float] = []
                while outputFramesWritten < outputFrames {
                    let sourcePosition = Double(outputFramesWritten)
                        * Double(manifest.master.sampleRate) / 16000
                    let lower = min(
                        inputFrames - 1,
                        max(0, Int64(sourcePosition.rounded(.down))),
                    )
                    // Hold the final input frame until the next block (or EOF)
                    // so interpolation remains continuous across read chunks.
                    if lower >= blockEnd - 1 { break }
                    let first = lower < blockStart
                        ? previousFrame
                        : masterSamples[Int(lower - blockStart)]
                    let upper = lower + 1
                    let second = upper < blockStart
                        ? previousFrame
                        : masterSamples[Int(upper - blockStart)]
                    let fraction = Float(sourcePosition - Double(lower))
                    derivativeSamples.append(first + ((second - first) * fraction))
                    outputFramesWritten += 1
                }
                if !derivativeSamples.isEmpty {
                    try output.write(contentsOf: MasterAudioWriter.float32LEData(derivativeSamples))
                }
                previousFrame = masterSamples[masterSamples.count - 1]
                hasPreviousFrame = true
                inputFramesRead = blockEnd
            }
            carry = completeLength == combined.count ? Data() : Data(combined.dropFirst(completeLength))
        }
        guard carry.isEmpty, inputFramesRead == inputFrames, hasPreviousFrame else {
            throw AudioManifestError.invalidFile
        }
        var finalSamples: [Float] = []
        while outputFramesWritten < outputFrames {
            let sourcePosition = Double(outputFramesWritten)
                * Double(manifest.master.sampleRate) / 16000
            let lower = min(
                inputFrames - 1,
                max(0, Int64(sourcePosition.rounded(.down))),
            )
            guard lower >= inputFrames - 1 else { throw AudioManifestError.invalidFile }
            finalSamples.append(previousFrame)
            outputFramesWritten += 1
        }
        if !finalSamples.isEmpty {
            try output.write(contentsOf: MasterAudioWriter.float32LEData(finalSamples))
        }
        guard outputFramesWritten == outputFrames else { throw AudioManifestError.invalidFile }
        try output.synchronize()
        return Double(outputFramesWritten) / 16000
    }

    private static func decodeMasterMono(_ data: Data, channels: Int) -> [Float] {
        let values = decodeFloat32LE(data)
        let frames = values.count / channels
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            let start = frame * channels
            var sum: Float = 0
            for channel in 0 ..< channels {
                let value = values[start + channel]
                sum += value.isFinite ? value : 0
            }
            mono[frame] = sum / Float(channels)
        }
        return mono
    }

    private static func decodeFloat32LE(_ data: Data) -> [Float] {
        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        for index in values.indices {
            let offset = index * 4
            let bits = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            values[index] = Float(bitPattern: bits)
        }
        return values
    }
}
