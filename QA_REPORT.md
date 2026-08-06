# ClassScribe QA Report

Date: 6 August 2026

This is a release-evidence ledger, not a claim that compilation alone completes
the MVP. Hardware, GitHub Actions and final-binary results remain explicitly
pending until they are run on the final commit.

## Environment

- Apple Silicon macOS host.
- Apple Swift 6.1.2.
- Local developer directory: Command Line Tools only.
- Full Xcode is intentionally not installed locally; Xcode Debug/Release and
  AudioTap XCTest run in GitHub Actions on `macos-15`.
- Private audio, transcript, recovery files, logs and crash reports remain
  outside Git.

## Completed local checks

| Check | Result | Evidence |
| --- | --- | --- |
| ClassScribe Debug + strict concurrency | Pass | SwiftPM built app, IPC target, helper and tests with `-strict-concurrency=complete`. |
| ClassScribe tests | Pass | Runner reported 52 cases passed, with 5 hardware/model/private opt-in cases explicitly skipped and 0 failures. |
| Native-abort containment | Pass | Injected helper dies by `SIGABRT`; parent test process continues and maps signal 6. |
| Helper success/malformed/missing/cancel paths | Pass | Valid IPC decoded; missing/malformed output rejected; temporaries cleaned; source bytes unchanged. |
| Real recovered-audio diarization | Pass | Private opt-in test processed the full 203-second copy, detected at least two voices in 6.220 seconds and left the WAV hash unchanged. |
| Real legacy-session scan | Pass | Private opt-in test marks the affected session recoverable/retryable, prefers its recovered TXT, materializes owner-only live TXT/Markdown and preserves legacy JSON bytes. |
| ASR failure resilience | Pass | Injected failure keeps WAV, live TXT and copy fallback. |
| Diarization failure resilience | Pass | Injected failure occurs only after full TXT/Markdown/JSON persistence; app state remains recoverable. |
| Recovery/history | Pass | Tests cover missing metadata, legacy JSON, recovered TXT, invalid WAV, RAW-only reconstruction with evidence preservation, symlink rejection, private directories, failed metadata and stable folder identity. |
| Live durability | Pass | Tests cover 10 and 100 windows, incompatible hypotheses, overlap, empty/error, pause/stop, restart reconstruction, journal, mode `0600` and rejection of queued audio from an older session generation. |
| Export/copy policy | Pass | Selected-tab professor/all/live source, ChatGPT envelope, free edits in TXT/Markdown, segmented-SRT warning and empty-output rejection. |
| Retry coordination | Pass | A retry becomes busy before its first suspension, is single-flight and cannot mutate a different restored session; cancellation preserves the WAV and live text. |
| WAV fixtures | Pass | Valid, silence, continuous signal, empty, header-only, truncated and streaming RAW wrapping. |
| Shell/YAML/diff syntax | Pass | Launcher/pre-push/lint shell syntax, workflow YAML parsing and `git diff --check`. |
| Private-data scan | Pass | Diff/untracked-name scan found no personal absolute path, audio, transcript, crash report or retained private hash. |

The tracked package resolves and builds through the ignored local mirror. A
direct `swift package resolve` against the remote dependency is blocked on this
host by the known incomplete Command Line Tools installation (`SwiftBridging`
module redefinition); it did not change `Package.resolved`. Official remote
resolution remains an explicit GitHub/Xcode gate and is not counted as a local
pass.

Representative local command (the mirror is ignored and exists only to work
around the local Command Line Tools installation):

```bash
export SWIFTPM_CUSTOM_LIBS_DIR="$(./scripts/prepare_local_toolchain.sh)"
swift test --package-path .toolchain/ClassScribePackage -j 2 \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift"
```

## AudioTap local limitation

`AudioTapLib` compiles and links as part of ClassScribe. Running its standalone
XCTest target locally stops at `no such module 'XCTest'` because this Command
Line Tools SDK does not ship XCTest. This is not counted as a pass. GitHub CI
must run the entire AudioTap XCTest suite, including the new 25-cycle callback
gate and exact-once stop tests, using Xcode.

## Automated cases represented in source

- Safe closure: repeated stop, deinit after stop, 25 stop cycles, callback drain,
  rejection of callbacks after close and gate restart.
- Transcript: monotonic chunks, overlap deduplication, incompatible replacement,
  pause/resume/stop, 100-window stress and legacy reconstruction.
- Persistence: atomic TXT/Markdown/JSON, append-only journal, owner-only mode,
  final-before-diarization order and edit persistence.
- Recovery: missing/corruptible metadata paths, valid/invalid WAV, RAW-only
  session reconstruction without deleting evidence, JSON-only session,
  recovered TXT preference, retry from persisted ASR and stable history.
- Processing: final ASR failure, diarization failure, successful retry, model
  cancellation, helper exit/signal/malformed/missing response and cancellation.
- Speaker/export: automatic/manual professor selection, reversible filtering,
  review retention, fallback copy, Unicode filenames and honest SRT behavior.

## CI and sanitizer gates

The main workflow must be green after the final push for:

- SwiftPM Debug and Release with complete strict concurrency.
- ClassScribe Swift Testing suite.
- AudioTap XCTest suite.
- Xcode Debug and Release builds for ClassScribe.
- Xcode Release build for `ClassScribeDiarizer`.
- Assembled bundle, nested signature, helper presence and embedded commit match.

The manual sanitizer workflow runs Address Sanitizer and Thread Sanitizer as
separate jobs for ClassScribe and AudioTap without `continue-on-error`. A runner
or dependency incompatibility will be recorded as such and will not be called a
pass.

Current status: pending final commit and workflow runs.

## Physical release gates

Still required on the exact final build:

1. 45–60 second built-in-microphone class: meter, monotonic text, growing TXT,
   copy, stop, valid WAV and no new crash report. The two earlier attempts
   failed and are retained as diagnostic evidence; neither is counted here.
2. 60–90 second Chrome class: selected-process capture, meter, text/TXT, stop,
   valid WAV, final processing and history.
3. Relaunch: recovered/history session opens in-app, copies, opens TXT/folder
   and reports the same final commit.

Current status: pending. No physical path is reported as passed until the user
performs these short interactions and the resulting files/log state are checked.
