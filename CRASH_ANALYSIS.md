# ClassScribe Stop-Crash Analysis

## Incident

- Physical in-person microphone session, 6 August 2026.
- Recording started at `14:34:36Z` and explicit stop began at approximately
  `14:37:59Z`.
- Crash capture time: `14:38:09.4435Z` (`11:38:09.4435 -0300`).
- Diagnostic source: the matching local ClassScribe `.ips` report (kept outside Git).
- Binary UUID: `C2D01626-7713-3E79-B6AD-2FA7118C723C`, matching the preserved
  build used for symbolication.

No private audio or transcript content is included in this document.

## Audio evidence and timeline

The microphone path succeeded and completed before the abort:

| Time (UTC) | Event |
| --- | --- |
| `14:34:36Z` | Requested built-in microphone was applied; hardware/tap format was 48 kHz mono. |
| `14:34:36Z` | Engine prepared and started; first written buffer contained 1,360 frames. |
| `14:37:59Z` | Stop recorded 2,030 callbacks, 3,247,845 written frames, 6,495,690 theoretical PCM bytes, zero restarts and no terminal capture error. |
| `14:37:59.425Z` | The user initiated Stop. |
| `14:37:59.434Z` | AVAudioEngine stopped and its IO transport ended. |
| `14:37:59Z` | The same stop metric line appeared a second time. This proves a second `stop()` invocation, currently caused by explicit stop followed by `deinit`. |
| `14:37:59.551Z` | Final processing began reading the finalized WAV. |
| `14:38:03.431Z` | Diarization model loading began. |
| `14:38:06.937Z` | Diarization opened/converted the WAV. |
| `14:38:09.252Z` | MPSGraph reported an executable error. |
| `14:38:09.4435Z` | The process terminated with `SIGABRT`. |

The finalized WAV independently validates as 16 kHz mono Int16 PCM, 3,248,176
frames, 6,496,352 audio bytes and 203.011 seconds. Audio teardown therefore
finished roughly ten seconds before the crash and did not cause this incident.

## Crash report

- Exception Type: `EXC_CRASH`.
- Signal: `SIGABRT`.
- Termination namespace: `SIGNAL`.
- Termination reason: `Abort trap: 6`.
- Faulting thread: 14, inside Metal / MetalPerformanceShadersGraph / Espresso /
  Core ML dispatch work.

The faulting thread contains the abort implementation rather than Swift frames.
The related application worker thread (thread 7) was symbolicated against the
exact binary UUID as:

1. `OfflineEmbeddingExtractor.runFbankBatch(audioArrays:)`
2. `flushFbankBatch` inside
   `OfflineEmbeddingExtractor.extractEmbeddings(audioSource:segmentationStream:)`
3. `OfflineEmbeddingExtractor.extractEmbeddings`
4. closure in `OfflineDiarizerManager.process`

The FluidAudio source location in `extractEmbeddings` is reached when the FBANK
batch hits its configured limit. FluidAudio 0.15.5 uses an embedding batch size
of 32, so the demonstrated trigger was the first full 32-entry FBANK embedding
batch. A smaller warmup prediction had succeeded earlier. The private internal
MPSGraph error text was redacted by unified logging and cannot be recovered from
the retained evidence.

The system stack on the faulting thread passes through
MetalPerformanceShadersGraph, Metal, Espresso and Core ML before the C runtime
abort. The final application-owned operation was therefore FluidAudio offline
speaker-embedding extraction during diarization.

## Demonstrated root cause

ClassScribe ran `OfflineDiarizerManager.process` in its own process immediately
after full-file transcription. A fatal MPSGraph/Core ML assertion issued
`SIGABRT`. Swift `do/catch` cannot catch a process-level abort, so the entire app
closed even though capture and WAV finalization had succeeded.

This incident was not an `AVAudioNode.removeTap`, AVAudioEngine, AVAudioFile,
callback-use-after-free or SwiftUI crash. Those remain important lifecycle risks,
but the timestamps and stacks exclude them as the cause of this crash.

The retained diagnostics do not contain an exact timestamp for the final render
callback, tap removal or `AVAudioFile` release. The evidence bounds the last
callback at or before `14:37:59.434Z`, and proves file finalization/validation
completed before processing opened it at `14:37:59.551Z`.

## Additional stop defects discovered

The investigation also established defects that must be fixed independently:

- `MicCaptureHandler.stop()` did not clear `tapInstalled`, so `deinit` could
  attempt a second tap removal and engine reset.
- Render callbacks read writer/converter/lifecycle state while stop mutated that
  state without an explicit drain barrier.
- `ClassScribeModel.stopClass()` was synchronous and had no stopping guard.
- The promoted provisional transcript was not checkpointed before native audio
  shutdown.
- Final ASR output existed only in a local variable until diarization succeeded.
  A diarization abort therefore also loses the useful final transcript.

These defects did not trigger the recorded `SIGABRT`, but leaving them in place
would violate safe-stop and durability requirements.

## Corrective architecture

1. Checkpoint the complete live transcript before audio stop.
2. Make model/controller/audio stop operations explicitly stateful and
   idempotent, and drain in-flight writes before closing the file.
3. Persist full-file transcription before starting diarization.
4. Run offline diarization in the separately signed `ClassScribeDiarizer`
   helper. A native abort produces a failed child status that the parent converts
   into a retryable error while preserving the app, WAV and text.
5. Use CPU-only compute and an embedding batch size of 1. The latter avoids the
   demonstrated full-batch FBANK path; process isolation remains the hard crash
   containment boundary.
6. Add regression tests for subprocess signal termination, double stop,
   in-flight stop and final-transcript preservation when diarization fails.

## Verification gates

Local automated tests now demonstrate parent survival after a child `SIGABRT`,
response validation/cancellation and final-text preservation after diarization
failure. AudioTap XCTest cases cover callback drain and double stop and await the
Xcode CI runner because local Command Line Tools do not provide XCTest. The
isolated helper also completed the recovered 203-second audio without modifying
it and detected multiple speakers. Final CI and short physical microphone/Chrome
sessions remain the release gates.
