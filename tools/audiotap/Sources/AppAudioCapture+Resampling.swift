@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log

private let masterAudioLogger = Logger(
    subsystem: "com.meetingtranscriber.audiotap",
    category: "AppAudioCaptureMaster",
)

/// Capture-time conversion for `AppAudioCapture`. The online path writes the
/// source-rate Float32 master and independently folds each CATap buffer to
/// 16 kHz mono for ASR/live use. The legacy path retains its fixed-rate write.
/// Extracted to a sibling file so `AppAudioCapture.swift` stays under the
/// 600-line lint cap — same pattern as `AppAudioCapture+LiveSink.swift`.
@available(macOS 14.2, *)
public extension AppAudioCapture {
    /// Format of the durable data written to the output fd: the selected master
    /// format when the online master writer is active, otherwise the legacy
    /// 16 kHz mono path (or raw device input as a fallback).
    var outputSampleRate: Int {
        if let masterFormat = masterWriter?.format {
            return masterFormat.sampleRate
        }
        return resampler != nil ? Int(speechSampleRate) : actualSampleRate
    }

    var outputChannels: Int {
        if let masterFormat = masterWriter?.format {
            return masterFormat.channels
        }
        return resampler != nil ? 1 : actualChannels
    }

    /// The buffer's hardware presentation time in mach ticks, for wall-clock
    /// gap-filling. Falls back to the callback clock if the IOProc didn't mark
    /// the host time valid.
    internal static func hostTicks(from time: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        let stamp = time.pointee
        return stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
    }

    /// In the legacy path, resample + downmix one interleaved CATap buffer to
    /// 16 kHz mono and write it to `fd`, also forwarding the resampled buffer to
    /// the live sink. The converter is rebuilt on a mid-recording rate change.
    /// The resampler buffers internally, so a buffer that yields no output yet
    /// (converter priming) is simply not written — its samples emerge on a
    /// later call, no data lost.
    /// Falls back to the raw native-rate write *and* raw-format live-sink forward
    /// only if no resampler was built (not expected for a 16 kHz target).
    /// `hostTicks` is the buffer's hardware presentation time, used to fill
    /// device-restart gaps with silence so the track stays aligned to wall-clock.
    /// Runs on `writeQueue`.
    internal func writeCapturedBuffer(
        fd: Int32, data: UnsafeMutableRawPointer, byteCount: Int, hostTicks: UInt64,
    ) {
        // The IOProc entry check admits a callback, but a generation advance
        // may happen while the callback is preparing the resampler. Recheck at
        // the durable boundary so an admitted old callback cannot write after
        // the handoff has invalidated its source generation.
        guard sourceCallbackGate?() ?? true else { return }
        guard resampler != nil else {
            writeAllToFileHandle(fd, data, count: byteCount)
            forwardToLiveSink(data: data, byteCount: byteCount)
            return
        }
        let floatCount = byteCount / MemoryLayout<Float>.size
        let interleaved = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: floatCount,
        ))
        if let masterWriter {
            do {
                _ = try masterWriter.append(
                    interleaved,
                    inputRate: actualSampleRate,
                    inputChannels: max(actualChannels, 1),
                    hostTicks: hostTicks,
                    sourceGeneration: sourceGeneration,
                )
            } catch {
                masterWriter.recordFailure(error)
                masterAudioLogger.error(
                    "Master audio write failed: \(error.localizedDescription, privacy: .public)",
                )
            }
            // ASR/live remains an independent fixed 16 kHz mono branch.
            resampleAndForward(
                interleaved: interleaved,
                inputRate: actualSampleRate,
                inputChannels: max(actualChannels, 1),
            )
            return
        }
        resampleForwardAndWrite(
            fd: fd, interleaved: interleaved,
            inputRate: actualSampleRate, inputChannels: max(actualChannels, 1),
            hostTicks: hostTicks,
        )
    }

    /// Core of `writeCapturedBuffer`, parameterised on the input rate/channels so
    /// it's drivable without a live CATap. Resamples to 16 kHz mono, fills any
    /// device-restart gap with silence (file only — the live path doesn't need
    /// gap-fill), writes the resampled samples to `fd`, and forwards those same
    /// samples to the live sink. Caller guarantees `resampler != nil`.
    internal func resampleForwardAndWrite(
        fd: Int32, interleaved: [Float], inputRate: Int, inputChannels: Int, hostTicks: UInt64,
    ) {
        guard let resampler else { return }
        let mono16k = resampler.process(
            interleaved, inputRate: inputRate, inputChannels: inputChannels,
        )
        // Converter priming can yield no output even though the native callback
        // is alive. Forward an empty callback so signal health records a live
        // silent transport instead of waiting for a non-empty buffer.
        guard !mono16k.isEmpty else {
            guard sourceCallbackGate?() ?? true else { return }
            forwardToLiveSink(monoSamples: [])
            return
        }
        guard sourceCallbackGate?() ?? true else { return }
        fillTimelineGap(fd: fd, hostTicks: hostTicks, outputFrames: mono16k.count)
        Self.writeFloats(mono16k, to: fd)
        forwardToLiveSink(monoSamples: mono16k)
    }

    /// ASR/live half of the split master path. It never writes the durable
    /// descriptor and therefore cannot redefine or shorten the master.
    internal func resampleAndForward(
        interleaved: [Float], inputRate: Int, inputChannels: Int,
    ) {
        guard let resampler else { return }
        let mono16k = resampler.process(
            interleaved, inputRate: inputRate, inputChannels: inputChannels,
        )
        guard !mono16k.isEmpty else {
            guard sourceCallbackGate?() ?? true else { return }
            forwardToLiveSink(monoSamples: [])
            return
        }
        guard sourceCallbackGate?() ?? true else { return }
        forwardToLiveSink(monoSamples: mono16k)
    }

    /// Write silence for a device-restart gap before this buffer's audio, so the
    /// app track stays aligned to wall-clock (issue #379 follow-up). Mirrors
    /// `MicCaptureHandler.fillTimelineGap`; the `TimelineAnchor` self-anchors on
    /// the first buffer and is never reset, so only a real gap produces silence.
    private func fillTimelineGap(fd: Int32, hostTicks: UInt64, outputFrames: Int) {
        let silence = timelineAnchor.silenceFramesBefore(
            hostSeconds: machTicksToSeconds(hostTicks), frameCount: outputFrames,
        )
        guard silence > 0 else { return }
        Self.writeFloats([Float](repeating: 0, count: silence), to: fd)
    }

    /// Write a float buffer's raw bytes to `fd` in one POSIX write loop.
    private static func writeFloats(_ samples: [Float], to fd: Int32) {
        samples.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                writeAllToFileHandle(fd, base, count: raw.count)
            }
        }
    }
}
