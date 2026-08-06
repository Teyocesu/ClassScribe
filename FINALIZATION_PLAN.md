# ClassScribe MVP Finalization Plan

This document tracks the evidence and gates required before ClassScribe can be
called ready for a first real class. A green build alone is not completion.

## Confirmed problems and evidence

| Area | Confirmed evidence | Required outcome |
| --- | --- | --- |
| Stop crash | Exact crash evidence proves a FluidAudio/Core ML `SIGABRT` during the first full FBANK batch, roughly ten seconds after the WAV closed. | Implemented: diarization runs in a signed subprocess, CPU-only with batch size 1; signal failure is retryable in the parent. |
| Live transcript loss | The affected session retained only a recent provisional snapshot; an incompatible hypothesis replaced the previous provisional. | Implemented: committed chunks are monotonic and the previous provisional is promoted before every new hypothesis. |
| Human-readable persistence | The old implementation persisted only a replaceable JSON snapshot. | Implemented: atomic owner-only TXT/Markdown plus append-only journal after every ASR result and lifecycle checkpoint. |
| Crash recovery | The affected session had a valid 16 kHz mono WAV but no metadata or final outputs. | Implemented and locally proven: legacy sessions appear as recoverable, materialize TXT without rewriting JSON and can retry valid WAVs. |
| UI/copy lifecycle | Copy and visible-text selection previously depended on final-state fields that could be empty. | Implemented: one fallback policy keeps editable/visible text and Copy/Open controls available during processing and errors. |
| Final pipeline resilience | Final ASR previously remained only in memory until diarization completed. | Implemented: full TXT/Markdown/JSON persist before the isolated diarization job; failure keeps these outputs. |
| Export consistency | Markdown/SRT previously ignored visible edits without warning. | Implemented: TXT/Markdown/copy use edits; SRT uses timestamped segments and presents an explicit warning. |
| Physical coverage | Two microphone attempts on earlier binaries failed; the exact executed binary and empty-WAV evidence were audited instead of being counted as passes. | Short microphone, Chrome and relaunch tests pass on the exact final binary. |

## Preserved evidence

- The affected real-session directory remains untouched.
- A private, owner-only backup outside the operational `Classes` directory was
  verified by size and SHA-256.
- The original WAV has a valid finalized header, 16 kHz mono Int16 PCM and a
  duration just over three minutes.
- Private audio, transcripts, logs, crash reports and personal paths must never
  be committed.

## Principal risks

1. Physical microphone and Chrome validation must still prove the automated
   callback-drain and idempotent-stop guarantees on the final binary.
2. A device/configuration observer may initiate a restart while explicit stop is
   underway.
3. Main-actor synchronous shutdown or inference cancellation may freeze or
   reorder persistence.
4. Sliding-window ASR hypotheses are revisions, not independent chunks; naive
   replacement loses text while naive appending duplicates full windows.
5. Recovery must continue interpreting legacy JSON-only sessions without
   rewriting their evidence; automated and private opt-in checks now cover it.
6. Model and sanitizer jobs may be limited by runner resources; unsupported
   combinations must be documented instead of treated as passes.

## Correction order

1. Preserve and recover the affected session.
2. Establish the crash timeline and smallest demonstrated stop race.
3. Make stop stateful, asynchronous and idempotent; checkpoint text first.
4. Introduce a monotonic live-transcript journal/checkpoint model.
5. Persist the human-readable TXT/Markdown and reconstruct legacy sessions.
6. Keep the best available transcript visible/copyable throughout all states.
7. Decouple full transcription, diarization, professor selection and exports.
8. Repair history/retry behavior and export source-of-truth rules.
9. Run unit, integration, persistence, stress and sanitizer QA.
10. Publish, wait for green CI, launch the exact final commit and complete the
    short physical microphone, Chrome and relaunch tests.

## Test matrix

| Layer | Cases | Evidence gate |
| --- | --- | --- |
| Accumulator | 10/100 windows; overlap; shared/no prefix; incompatible/empty/error hypotheses; punctuation; technical text; partial words; pause/resume; stop | Confirmed content never shrinks, old paragraphs remain, whole windows do not duplicate, final provisional survives. |
| Stop coordination | 25 start/stop cycles with fakes; double stop; stop during ASR/write/restart; deinit; engine error | One tap removal/engine stop/file close, same cached result on repeat, no callback writes after close. |
| Persistence | Checkpoint per result/pause/stop/error; atomic replacement; mode `0600`; JSON/journal reconstruction | TXT always equals visible text and survives simulated interruption/relaunch. |
| Recovery | WAV + JSON; WAV + TXT; invalid WAV + text; missing final outputs; failed/finalizing metadata | Session is listed as recoverable and text remains viewable/copyable without modifying originals. |
| Final processing | Full-ASR failure; diarization failure; professor-selection failure; retry | Best prior text remains; full text is saved before diarization; no empty successful state. |
| UI/copy | Recording, stopping, final processing, completed and failed | Scrollable/selectable text and Copy/Open controls remain available with correct fallback. |
| Export | Edited/unedited TXT and Markdown; segmented/free-edit SRT; accented/long names | No silent empty files; visible edits are honored and SRT limitation is explicit. |
| Audio fixtures | Valid/header-only/truncated/empty/silent/continuous Spanish/two-speaker | Correct validation/failure; original input is never deleted. |
| Build/quality | SwiftPM Debug/Release, ClassScribe tests, AudioTap tests, strict concurrency, Xcode Debug/Release, ASan/TSan where supported | Every required job green or an exact, documented incompatibility for optional sanitizer jobs. |
| Physical | 45–60 s microphone; 60–90 s Chrome; relaunch | Valid WAV/TXT, monotonic visible text, safe stop, history recovery, exact final build identity. |

## Acceptance criteria

Completion requires evidence for every item in the user's 25-point definition:
safe stop; valid microphone and Chrome WAVs; monotonic visible/live TXT text;
copy across all lifecycle states; preserved provisional/audio on failure; resilient
full transcription and diarization; professor switching without loss; correct
exports/edits; persistent recoverable history; passing relevant tests and final
CI; one running binary from the final commit; and the three short physical
checks.

## Recovery strategy

- Never mutate the original evidence while attempting recovery.
- Work from a private owner-only copy and verify hashes before processing.
- Transcribe the valid WAV independently of diarization and save recovered TXT
  and Markdown alongside the private session.
- When the app encounters a legacy JSON-only session, synthesize a readable TXT
  atomically from stable plus provisional text while retaining the JSON.
- Treat a session with useful text but invalid audio as recoverable-for-reading,
  not empty or disposable.
- Treat a valid WAV without final outputs as retryable processing work.

## Progress ledger

- Phase 0 repository/toolchain/disk inspection: complete.
- Private backup and WAV validation: complete.
- Session transcription recovery (TXT + Markdown): complete.
- Crash forensics and exact-binary symbolication: complete.
- Safe/idempotent audio stop and callback drain: implemented; XCTest CI pending.
- Monotonic transcript, TXT/Markdown journal and restart reconstruction: complete in local tests.
- Isolated diarization: helper build, signal-containment test and real private-audio run complete.
- Recoverable history, RAW-only reconstruction, single-flight retry, in-app
  load/copy/retry and selected-tab export edits: complete in local tests.
- Full local Debug/Release, strict-concurrency review and GitHub CI: in progress.
- Final microphone, Chrome and relaunch checks: pending until the exact final commit is open.
