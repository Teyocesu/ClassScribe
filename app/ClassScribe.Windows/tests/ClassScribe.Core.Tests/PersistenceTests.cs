using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class PersistenceTests
{
    private static readonly JsonSerializerOptions WebJsonOptions = new(JsonSerializerDefaults.Web);
    private string temporaryRoot = null!;

    [TestInitialize]
    public void SetUp()
    {
        temporaryRoot = Path.Combine(Path.GetTempPath(), $"classscribe-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temporaryRoot);
    }

    [TestCleanup]
    public void TearDown()
    {
        if (Directory.Exists(temporaryRoot))
        {
            Directory.Delete(temporaryRoot, recursive: true);
        }
    }

    [TestMethod]
    public async Task RawAudioIsWrappedIntoAValidRecoverableWave()
    {
        var raw = Path.Combine(temporaryRoot, "source.raw");
        var wave = Path.Combine(temporaryRoot, "source.wav");
        var samples = new byte[PcmWaveFile.SampleRate * 2];
        await File.WriteAllBytesAsync(raw, samples);

        var duration = await PcmWaveFile.WrapRawAsync(raw, wave);

        Assert.AreEqual(1, duration, 0.001);
        Assert.AreEqual(1, PcmWaveFile.Validate(wave), 0.001);
        Assert.IsTrue(File.Exists(raw), "Wrapping must preserve the crash-recovery source until commit.");
    }

    [TestMethod]
    public void TruncatedWaveIsRejected()
    {
        var path = Path.Combine(temporaryRoot, "source.wav");
        File.WriteAllBytes(path, "RIFF"u8.ToArray());

        Assert.ThrowsExactly<InvalidDataException>(() => PcmWaveFile.Validate(path));
    }

    [TestMethod]
    public async Task WaveSamplesAreDecodedForTheIsolatedDiarizer()
    {
        var raw = Path.Combine(temporaryRoot, "samples.raw");
        var wave = Path.Combine(temporaryRoot, "samples.wav");
        await File.WriteAllBytesAsync(raw, [0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80]);
        await PcmWaveFile.WrapRawAsync(raw, wave);

        var samples = PcmWaveFile.ReadSamples(wave);

        Assert.HasCount(3, samples);
        Assert.AreEqual(0, samples[0], 0.0001);
        Assert.AreEqual(32767 / 32768f, samples[1], 0.0001);
        Assert.AreEqual(-1, samples[2], 0.0001);
    }

    [TestMethod]
    public void SameSecondSessionsReceiveUniqueFolders()
    {
        var store = new SessionStore(temporaryRoot);
        var date = new DateTimeOffset(2026, 8, 23, 12, 30, 45, TimeSpan.Zero);

        var first = store.CreateFolder("Álgebra", date);
        var second = store.CreateFolder("Álgebra", date);

        Assert.AreNotEqual(first, second);
        StringAssert.Contains(Path.GetFileName(first), "_álgebra-");
        StringAssert.Contains(Path.GetFileName(second), "_álgebra-");
    }

    [TestMethod]
    public async Task IncompleteSessionIsDiscoveredWithoutMetadata()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Historia", DateTimeOffset.Now);
        var raw = Path.Combine(folder, "source.raw");
        await File.WriteAllBytesAsync(raw, new byte[PcmWaveFile.SampleRate * 2]);
        await File.WriteAllTextAsync(Path.Combine(folder, "live-transcript.txt"), "Texto parcial");

        var sessions = store.ScanSessions();
        Assert.HasCount(1, sessions);
        var session = sessions[0];

        Assert.IsTrue(session.IsRecoverable);
        Assert.IsTrue(session.HasRecoverableRaw);
        Assert.IsFalse(session.HasValidAudio);
        Assert.IsNotNull(session.PreferredTextPath);
        Assert.AreEqual("historia", session.Metadata.Subject);
    }

    [TestMethod]
    public async Task TruncatedLegacyMetadataRemainsRecoverableAndReadOnly()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Metadata truncada", DateTimeOffset.Now);
        var metadataPath = Path.Combine(folder, "metadata.json");
        var corruptMetadata = "{\"schemaVersion\":1,\"state\":\"recording\""u8.ToArray();
        await File.WriteAllBytesAsync(metadataPath, corruptMetadata);
        await File.WriteAllBytesAsync(
            Path.Combine(folder, "source.raw"),
            new byte[PcmWaveFile.SampleRate * 2]);
        await File.WriteAllTextAsync(Path.Combine(folder, "live-transcript.txt"), "texto parcial conservado");

        var summary = new SessionStore(temporaryRoot).ScanSessions().Single();

        Assert.IsTrue(summary.IsRecoverable);
        StringAssert.Contains(summary.RecoveryReason!, "truncada");
        CollectionAssert.AreEqual(corruptMetadata, await File.ReadAllBytesAsync(metadataPath));
        Assert.AreEqual("texto parcial conservado", await File.ReadAllTextAsync(summary.PreferredTextPath!));
    }

    [TestMethod]
    public async Task StoreRejectsWritesOutsideItsRoot()
    {
        var store = new SessionStore(Path.Combine(temporaryRoot, "sessions"));
        var metadata = new ClassMetadata { Subject = "Química" };

        await Assert.ThrowsExactlyAsync<UnauthorizedAccessException>(
            () => store.SaveMetadataAsync(metadata, temporaryRoot));
    }

    [TestMethod]
    public async Task StoreRejectsASymbolicSessionDirectory()
    {
        var sessionsRoot = Path.Combine(temporaryRoot, "sessions");
        var outside = Path.Combine(temporaryRoot, "outside");
        Directory.CreateDirectory(sessionsRoot);
        Directory.CreateDirectory(outside);
        var linkedSession = Path.Combine(sessionsRoot, "linked-session");
        await CreateDirectoryLinkAsync(linkedSession, outside);
        var store = new SessionStore(sessionsRoot);

        try
        {
            await Assert.ThrowsExactlyAsync<UnauthorizedAccessException>(
                () => store.SaveMetadataAsync(new ClassMetadata { Subject = "Privada" }, linkedSession));
        }
        finally
        {
            if (Directory.Exists(linkedSession))
            {
                Directory.Delete(linkedSession);
            }
        }
    }

    [TestMethod]
    public async Task RecoverRawAudioCommitsWaveBeforeRemovingRawSource()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Francés", DateTimeOffset.Now);
        var raw = Path.Combine(folder, "source.raw");
        await File.WriteAllBytesAsync(raw, new byte[PcmWaveFile.SampleRate * 2]);

        var wave = await store.RecoverRawAudioAsync(folder);

        Assert.IsTrue(File.Exists(wave));
        Assert.IsFalse(File.Exists(raw));
        Assert.AreEqual(1, PcmWaveFile.Validate(wave), 0.001);
    }

    [TestMethod]
    public async Task CorruptWaveDoesNotHideOrPreventRawAudioRecovery()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Audio interrumpido", DateTimeOffset.Now);
        var raw = Path.Combine(folder, "source.raw");
        var wave = Path.Combine(folder, "source.wav");
        await File.WriteAllBytesAsync(raw, new byte[PcmWaveFile.SampleRate * 2]);
        await File.WriteAllBytesAsync(wave, "RIFF"u8.ToArray());

        var sessions = store.ScanSessions();

        Assert.HasCount(1, sessions);
        Assert.IsFalse(sessions[0].HasValidAudio);
        Assert.IsTrue(sessions[0].HasRecoverableRaw);
        var recovered = await store.RecoverRawAudioAsync(folder);
        Assert.AreEqual(1, PcmWaveFile.Validate(recovered), 0.001);
        Assert.IsFalse(File.Exists(raw));
    }

    [TestMethod]
    public void LegacyWindowsFixtureOpensReadOnlyAndAppliesDefaults()
    {
        var fixture = FixturePath("windows-v0.7-inperson-recoverable");
        var folder = Path.Combine(temporaryRoot, "windows-v0.7-inperson-recoverable");
        Directory.CreateDirectory(folder);
        File.Copy(Path.Combine(fixture, "metadata.json"), Path.Combine(folder, "metadata.json"));
        File.Copy(Path.Combine(fixture, "all-speakers.json"), Path.Combine(folder, "all-speakers.json"));
        var before = File.ReadAllBytes(Path.Combine(folder, "metadata.json"));

        var summary = new SessionStore(temporaryRoot).ScanSessions().Single();

        Assert.AreEqual(1, summary.Metadata.SchemaVersion);
        Assert.AreEqual("es", summary.Metadata.Language);
        Assert.AreEqual(CaptureMode.InPerson, summary.Metadata.Mode);
        Assert.AreEqual(CaptureScope.Microphone, summary.Metadata.CaptureScope);
        Assert.AreEqual(SessionPhase.Recoverable, summary.Metadata.SessionPhase);
        Assert.AreEqual("Persona 1", summary.Metadata.ProfessorSpeakerID);
        Assert.IsTrue(summary.IsRecoverable);
        Assert.IsFalse(File.Exists(Path.Combine(folder, "live-transcript.txt")));
        CollectionAssert.AreEqual(before, File.ReadAllBytes(Path.Combine(folder, "metadata.json")));
    }

    [TestMethod]
    public void LegacyMacOSFixtureAcceptsSpanishStateAndApplicationScopeAliases()
    {
        var fixture = FixturePath("macos-v0.7-online-incomplete");
        var folder = Path.Combine(temporaryRoot, "macos-v0.7-online-incomplete");
        Directory.CreateDirectory(folder);
        File.Copy(Path.Combine(fixture, "metadata.json"), Path.Combine(folder, "metadata.json"));
        File.Copy(Path.Combine(fixture, "all-speakers.json"), Path.Combine(folder, "all-speakers.json"));

        var summary = new SessionStore(temporaryRoot).ScanSessions().Single();

        Assert.AreEqual(CaptureMode.Online, summary.Metadata.Mode);
        Assert.AreEqual(CaptureScope.Application, summary.Metadata.CaptureScope);
        Assert.AreEqual(SessionPhase.Recording, summary.Metadata.SessionPhase);
        Assert.AreEqual("es", summary.Metadata.Language);
        Assert.AreEqual("Persona 0", summary.Metadata.ProfessorSpeakerID);
    }

    [TestMethod]
    public async Task AsrOriginalAndHumanOverlayAreNotReplacedByDiarization()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Fuentes", DateTimeOffset.UtcNow);
        var raw = Path.Combine(folder, "source.raw");
        await File.WriteAllBytesAsync(raw, new byte[PcmWaveFile.SampleRate * 2]);
        var wave = Path.Combine(folder, "source.wav");
        await PcmWaveFile.WrapRawAsync(raw, wave);
        var sourceBefore = await File.ReadAllBytesAsync(wave);
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var original = new TranscriptSegment
        {
            Start = 0,
            End = 1,
            Text = "texto ASR original",
            SpeakerID = "Persona desconocida",
            Confidence = 0,
        };
        var metadata = new ClassMetadata
        {
            Id = attempt.SessionID,
            Subject = "Fuentes",
            StartedAt = DateTimeOffset.UtcNow,
            Duration = 1,
            Mode = CaptureMode.InPerson,
            CaptureScope = CaptureScope.Microphone,
            Source = "Micrófono",
            State = ProcessingState.Diarizing,
            SessionPhase = SessionPhase.Processing,
            CapturePhase = CapturePhase.Idle,
            AsrPhase = AsrPhase.Idle,
            AttemptID = attempt,
            FolderPath = folder,
        };
        var reference = await store.SaveAsrOriginalAsync(metadata, [original], folder);
        metadata = metadata with
        {
            AsrOriginalReference = reference,
            State = ProcessingState.Complete,
            SessionPhase = SessionPhase.Complete,
        };
        var assigned = original with { SpeakerID = "Persona 1", Confidence = 0.9 };
        var proposal = new DiarizationProposal
        {
            ProposalID = Guid.NewGuid(),
            CreatedAt = DateTimeOffset.UtcNow,
            EngineVersion = "test",
            AsrRunID = reference.RunID,
            Spans = [new DiarizationSpan { Start = 0, End = 1, SpeakerID = "Persona 1", Quality = 0.9 }],
        };

        await store.SaveFinalAsync(
            metadata,
            [assigned],
            [assigned],
            [],
            [],
            folder,
            humanCorrection: new HumanCorrectionUpdate
            {
                AllText = "corrección humana",
                ProfessorText = "corrección profesor",
            },
            diarizationProposal: proposal);

        var artifact = JsonSerializer.Deserialize<ASRTranscriptArtifact>(
            await File.ReadAllTextAsync(Path.Combine(folder, reference.RelativePath)), WebJsonOptions);
        var overlay = JsonSerializer.Deserialize<HumanCorrectionOverlay>(
            await File.ReadAllTextAsync(Path.Combine(folder, "human-correction-overlay.json")), WebJsonOptions);
        var persistedMetadata = JsonSerializer.Deserialize<ClassMetadata>(
            await File.ReadAllTextAsync(Path.Combine(folder, "metadata.json")), WebJsonOptions);
        Assert.AreEqual("Persona desconocida", artifact!.Segments.Single().SpeakerID);
        Assert.AreEqual("corrección humana", overlay!.EditedAllText);
        Assert.AreEqual(reference.RunID, persistedMetadata!.AsrOriginalReference!.RunID);
        Assert.IsTrue(persistedMetadata.DiarizationProposalReferences.Any(item => item.ProposalID == proposal.ProposalID));
        Assert.AreEqual("human-correction-overlay.json", persistedMetadata.HumanCorrectionOverlayReference!.RelativePath);
        CollectionAssert.AreEqual(sourceBefore, await File.ReadAllBytesAsync(wave));
        var persistedMetadataJson = await File.ReadAllTextAsync(Path.Combine(folder, "metadata.json"));
        StringAssert.Contains(persistedMetadataJson, "\"schemaVersion\": 2");
        StringAssert.Contains(persistedMetadataJson, "\"sessionPhase\": \"complete\"");
    }

    [TestMethod]
    public async Task AutomaticProjectionPreservesHumanOverlayAndPersistsNewStructuredResult()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Provenance", DateTimeOffset.UtcNow);
        var metadata = new ClassMetadata
        {
            Subject = "Provenance",
            StartedAt = DateTimeOffset.UtcNow,
            Mode = CaptureMode.InPerson,
            CaptureScope = CaptureScope.Microphone,
            Source = "Micrófono",
            State = ProcessingState.Complete,
            SessionPhase = SessionPhase.Complete,
            CapturePhase = CapturePhase.Idle,
            AsrPhase = AsrPhase.Idle,
            FolderPath = folder,
        };
        var humanAll = "corrección humana persistida";
        var humanProfessor = "corrección humana del profesor";
        await store.SaveEditedDocumentsAsync(metadata, folder, humanAll, humanProfessor);
        var overlayPath = Path.Combine(folder, "human-correction-overlay.json");
        var overlayBefore = await File.ReadAllBytesAsync(overlayPath);

        var automaticSegment = new TranscriptSegment
        {
            Start = 0,
            End = 1,
            Text = "resultado automático nuevo",
            SpeakerID = "Persona 2",
            Confidence = 0.95,
        };
        await store.SaveAutomaticProjectionAsync(
            metadata with { SpeakerCount = 1 },
            [automaticSegment],
            [automaticSegment],
            [],
            [],
            folder,
            automaticAllText: "resultado automático nuevo",
            automaticProfessorText: "profesor automático nuevo");

        CollectionAssert.AreEqual(overlayBefore, await File.ReadAllBytesAsync(overlayPath));
        Assert.AreEqual(humanAll, await File.ReadAllTextAsync(Path.Combine(folder, "all-speakers.txt")));
        Assert.AreEqual(humanProfessor, await File.ReadAllTextAsync(Path.Combine(folder, "professor.txt")));
        var persistedSegments = JsonSerializer.Deserialize<List<TranscriptSegment>>(
            await File.ReadAllTextAsync(Path.Combine(folder, "all-speakers.json")),
            WebJsonOptions);
        Assert.AreEqual("Persona 2", persistedSegments!.Single().SpeakerID);
        var persistedSegmentsJson = await File.ReadAllTextAsync(Path.Combine(folder, "all-speakers.json"));
        StringAssert.Contains(persistedSegmentsJson, "resultado automático nuevo");

        var freshFolder = store.CreateFolder("Automático sin overlay", DateTimeOffset.UtcNow);
        await store.SaveAutomaticProjectionAsync(
            metadata with { FolderPath = freshFolder },
            [automaticSegment],
            [automaticSegment],
            [],
            [],
            freshFolder,
            automaticAllText: "automático sin overlay",
            automaticProfessorText: "profesor sin overlay");
        Assert.IsFalse(File.Exists(Path.Combine(freshFolder, "human-correction-overlay.json")));
    }

    private static async Task CreateDirectoryLinkAsync(string link, string target)
    {
        try
        {
            Directory.CreateSymbolicLink(link, target);
        }
        catch (IOException symbolicLinkError) when (OperatingSystem.IsWindows())
        {
            await CreateJunctionOrMarkSetupInconclusiveAsync(link, target, symbolicLinkError);
        }
        catch (UnauthorizedAccessException symbolicLinkError) when (OperatingSystem.IsWindows())
        {
            await CreateJunctionOrMarkSetupInconclusiveAsync(link, target, symbolicLinkError);
        }

        var attributes = File.GetAttributes(link);
        Assert.IsTrue(
            (attributes & FileAttributes.ReparsePoint) != 0,
            "El enlace de directorio debe ser un reparse point.");
    }

    private static async Task CreateJunctionOrMarkSetupInconclusiveAsync(
        string link,
        string target,
        Exception symbolicLinkError)
    {
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                },
            };
            process.StartInfo.ArgumentList.Add("/c");
            process.StartInfo.ArgumentList.Add("mklink");
            process.StartInfo.ArgumentList.Add("/J");
            process.StartInfo.ArgumentList.Add(link);
            process.StartInfo.ArgumentList.Add(target);

            if (!process.Start())
            {
                throw new InvalidOperationException("cmd.exe no pudo iniciarse.");
            }

            var standardOutput = process.StandardOutput.ReadToEndAsync();
            var standardError = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            var output = await standardOutput;
            var errorOutput = await standardError;
            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    $"mklink /J terminó con código {process.ExitCode}. stdout: {output}; stderr: {errorOutput}");
            }
        }
        catch (Exception junctionError)
        {
            Assert.Inconclusive(
                $"No se pudo crear el enlace simbólico ni el junction local. "
                + $"Symlink: {symbolicLinkError}; junction: {junctionError}");
        }
    }

    [TestMethod]
    public void FutureMetadataIsUnsupportedAndNotRewritten()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Futuro", DateTimeOffset.UtcNow);
        var metadataPath = Path.Combine(folder, "metadata.json");
        var node = JsonNode.Parse(JsonSerializer.Serialize(new ClassMetadata { Subject = "Futuro" }))!.AsObject();
        node["schemaVersion"] = 3;
        File.WriteAllText(metadataPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.WriteAllText(Path.Combine(folder, "live-transcript.txt"), "texto conservado");
        var before = File.ReadAllBytes(metadataPath);

        Assert.AreEqual(0, store.ScanSessions().Count);
        CollectionAssert.AreEqual(before, File.ReadAllBytes(metadataPath));
    }

    [TestMethod]
    public void UnknownMetadataTokenIsUnsupportedAndNotRewritten()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Token desconocido", DateTimeOffset.UtcNow);
        var metadataPath = Path.Combine(folder, "metadata.json");
        var node = JsonNode.Parse(JsonSerializer.Serialize(new ClassMetadata { Subject = "Token" }))!.AsObject();
        node["state"] = "future-state";
        File.WriteAllText(metadataPath, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.WriteAllText(Path.Combine(folder, "live-transcript.txt"), "texto conservado");
        var before = File.ReadAllBytes(metadataPath);

        Assert.AreEqual(0, store.ScanSessions().Count);
        CollectionAssert.AreEqual(before, File.ReadAllBytes(metadataPath));
    }

    private static string FixturePath(string name) => Path.GetFullPath(Path.Combine(
        AppContext.BaseDirectory,
        "../../../Fixtures/LegacySessions",
        name));
}
