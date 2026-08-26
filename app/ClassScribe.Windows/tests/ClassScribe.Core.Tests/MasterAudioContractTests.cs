using System.Text.Json;
using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class MasterAudioContractTests
{
    private string temporaryRoot = null!;

    [TestInitialize]
    public void SetUp()
    {
        temporaryRoot = Path.Combine(Path.GetTempPath(), $"classscribe-master-tests-{Guid.NewGuid():N}");
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
    public void firstNonEmptyPcmChoosesMasterFormat()
    {
        var manifestPath = Path.Combine(temporaryRoot, "audio-manifest.json");
        var writer = new MasterAudioWriter(manifestPath);
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var generation = new CaptureSourceGeneration(attempt, 1);
        var inputFormat = AudioPcmFormat.Create(44_100, 2, AudioSampleEncoding.PcmS16LE);

        var empty = writer.PreparePacket(Array.Empty<byte>(), inputFormat, generation);

        Assert.IsTrue(empty.IsEmpty);
        Assert.IsNull(writer.Format);
        Assert.IsFalse(File.Exists(manifestPath));

        var packet = writer.PreparePacket(
            PcmAudioConverter.EncodePcmS16LE(new[] { 0.25f, -0.25f }),
            inputFormat,
            generation);

        Assert.IsFalse(packet.IsEmpty);
        Assert.AreEqual(44_100, writer.Format?.SampleRate);
        Assert.AreEqual(2, writer.Format?.Channels);
        Assert.AreEqual(AudioSampleEncoding.Float32LE, writer.Format?.Encoding);
        Assert.IsTrue(File.Exists(manifestPath));
        Assert.AreEqual(44_100, writer.Manifest?.Master.SampleRate);
        Assert.AreEqual(2, writer.Manifest?.Master.Channels);
    }

    [TestMethod]
    public void emptyCallbackDoesNotChooseMasterFormat()
    {
        var writer = new MasterAudioWriter(Path.Combine(temporaryRoot, "audio-manifest.json"));
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var generation = new CaptureSourceGeneration(attempt, 1);

        _ = writer.PreparePacket(
            Array.Empty<byte>(),
            AudioPcmFormat.Create(48_000, 2, AudioSampleEncoding.Float32LE),
            generation);

        Assert.IsNull(writer.Format);
        Assert.IsNull(writer.Manifest);
        Assert.AreEqual(0, writer.FramesWritten);
    }

    [TestMethod]
    public void staleCallbackCannotChooseMasterFormat()
    {
        var writer = new MasterAudioWriter(Path.Combine(temporaryRoot, "audio-manifest.json"));
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var currentGeneration = gate.Advance(attempt)!;
        var format = AudioPcmFormat.Create(48_000, 2, AudioSampleEncoding.Float32LE);
        var pcm = PcmAudioConverter.EncodeFloat32LE(new[] { 0.1f, -0.1f });

        if (gate.Accepts(attempt, oldGeneration))
        {
            _ = writer.PreparePacket(pcm, format, oldGeneration);
        }

        Assert.IsFalse(gate.Accepts(attempt, oldGeneration));
        Assert.IsNull(writer.Format);

        _ = writer.PreparePacket(pcm, format, currentGeneration);
        Assert.IsNotNull(writer.Format);
    }

    [TestMethod]
    public void masterFormatIsImmutableWithinAttempt()
    {
        var writer = new MasterAudioWriter(Path.Combine(temporaryRoot, "audio-manifest.json"));
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var firstGeneration = new CaptureSourceGeneration(attempt, 1);
        var secondGeneration = new CaptureSourceGeneration(attempt, 2);

        _ = writer.PreparePacket(
            PcmAudioConverter.EncodeFloat32LE(new[] { 0.1f, -0.1f, 0.2f, -0.2f }),
            AudioPcmFormat.Create(48_000, 2, AudioSampleEncoding.Float32LE),
            firstGeneration);
        _ = writer.PreparePacket(
            PcmAudioConverter.EncodePcmS16LE(new[] { 0.3f, -0.3f }),
            AudioPcmFormat.Create(44_100, 1, AudioSampleEncoding.PcmS16LE),
            secondGeneration);

        Assert.AreEqual(48_000, writer.Format?.SampleRate);
        Assert.AreEqual(2, writer.Format?.Channels);
        Assert.AreEqual(1, writer.Manifest?.Conversions.Count);
        Assert.AreEqual(48_000, writer.Manifest?.Conversions[0].OutputSampleRate);
        Assert.AreEqual(2, writer.Manifest?.Conversions[0].OutputChannels);
    }

    [TestMethod]
    public void inputFormatChangeIsConvertedNotConcatenated()
    {
        var writer = new MasterAudioWriter(Path.Combine(temporaryRoot, "audio-manifest.json"));
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var firstGeneration = new CaptureSourceGeneration(attempt, 1);
        var secondGeneration = new CaptureSourceGeneration(attempt, 2);
        var firstFormat = AudioPcmFormat.Create(48_000, 2, AudioSampleEncoding.Float32LE);
        var secondFormat = AudioPcmFormat.Create(44_100, 1, AudioSampleEncoding.PcmS16LE);

        var first = writer.PreparePacket(
            PcmAudioConverter.EncodeFloat32LE(new[] { 0.1f, -0.1f, 0.2f, -0.2f }),
            firstFormat,
            firstGeneration);
        var secondInput = PcmAudioConverter.EncodePcmS16LE(new[] { 0.3f, -0.3f });
        var second = writer.PreparePacket(secondInput, secondFormat, secondGeneration);

        Assert.AreEqual(first.FrameCount * first.Format.BytesPerFrame, first.Bytes.Length);
        Assert.AreEqual(second.FrameCount * second.Format.BytesPerFrame, second.Bytes.Length);
        Assert.AreEqual(AudioSampleEncoding.Float32LE, second.Format.Encoding);
        Assert.IsFalse(second.Bytes.SequenceEqual(secondInput));
    }

    [TestMethod]
    public void masterDurationDoesNotDependOnAsrDerivativeBytes()
    {
        var writer = new MasterAudioWriter(Path.Combine(temporaryRoot, "audio-manifest.json"));
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var generation = new CaptureSourceGeneration(attempt, 1);

        _ = writer.PreparePacket(
            PcmAudioConverter.EncodeFloat32LE(new[] { 0.1f, -0.1f }),
            AudioPcmFormat.Create(48_000, 2, AudioSampleEncoding.Float32LE),
            generation);
        writer.CommitFrames(48_000);

        Assert.AreEqual(1, writer.DurationSeconds, 0.000001);
    }

    [TestMethod]
    public async Task sourceWavIsAlways16kMonoForNewOnlineSession()
    {
        var (folder, master, manifest) = CreateOnlineMaster(48_000, 2, 480);
        var source = Path.Combine(folder, "source.wav");

        var duration = await PcmWaveFile.DeriveFromMasterAsync(master, manifest, source);

        Assert.AreEqual(0.01, duration, 0.0001);
        Assert.AreEqual(0.01, PcmWaveFile.Validate(source), 0.0001);
        Assert.HasCount(160, PcmWaveFile.ReadSamples(source));
        Assert.IsTrue(File.Exists(master));
        Assert.IsTrue(File.Exists(manifest));
    }

    [TestMethod]
    public async Task derivativeFailurePreservesMaster()
    {
        var folder = Path.Combine(temporaryRoot, "failed-derivative");
        Directory.CreateDirectory(folder);
        var master = Path.Combine(folder, "master.raw");
        var manifest = Path.Combine(folder, "audio-manifest.json");
        var source = Path.Combine(folder, "source.wav");
        WriteManifestAndMaster(manifest, master, 48_000, 2, [0.1f, -0.1f]);
        await File.WriteAllBytesAsync(master, [0, 1, 2]);
        var previousSource = "evidence-before-derivative"u8.ToArray();
        await File.WriteAllBytesAsync(source, previousSource);

        await Assert.ThrowsExceptionAsync<InvalidDataException>(() =>
            PcmWaveFile.DeriveFromMasterAsync(master, manifest, source));

        CollectionAssert.AreEqual(previousSource, await File.ReadAllBytesAsync(source));
        Assert.IsTrue(File.Exists(master));
        Assert.IsTrue(File.Exists(manifest));
    }

    [TestMethod]
    public async Task masterRecoveryRegeneratesDerivative()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Master recovery", DateTimeOffset.Now);
        var master = Path.Combine(folder, "master.raw");
        var manifest = Path.Combine(folder, "audio-manifest.json");
        WriteManifestAndMaster(manifest, master, 48_000, 2, new float[480 * 2]);

        var recovered = await store.RecoverRawAudioAsync(folder);

        Assert.AreEqual(Path.Combine(folder, "source.wav"), recovered);
        Assert.AreEqual(0.01, PcmWaveFile.Validate(recovered), 0.0001);
        Assert.IsTrue(File.Exists(master));
        Assert.IsTrue(File.Exists(manifest));
    }

    [TestMethod]
    public async Task legacySourceRawRecoveryStillWorks()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Legacy recovery", DateTimeOffset.Now);
        var raw = Path.Combine(folder, "source.raw");
        await File.WriteAllBytesAsync(raw, new byte[PcmWaveFile.SampleRate * 2]);

        var recovered = await store.RecoverRawAudioAsync(folder);

        Assert.AreEqual(1, PcmWaveFile.Validate(recovered), 0.0001);
        Assert.IsFalse(File.Exists(raw));
    }

    [TestMethod]
    public void oldMetadataWithoutManifestStillLoads()
    {
        var store = new SessionStore(temporaryRoot);
        var folder = store.CreateFolder("Legacy metadata", DateTimeOffset.Now);
        File.WriteAllText(
            Path.Combine(folder, "metadata.json"),
            "{\"schemaVersion\":1,\"mode\":\"online\",\"state\":\"ready\",\"subject\":\"Historia\"}");

        var summary = store.ScanSessions().Single();

        Assert.AreEqual("Historia", summary.Metadata.Subject);
        Assert.IsNull(summary.Metadata.AudioManifestReference);
        Assert.AreEqual(PcmWaveFile.AudioFormatName, summary.Metadata.AudioFormat);
    }

    [TestMethod]
    public void newMetadataReferencesManifestWithoutPersistingLocalizedFormatIdentity()
    {
        var metadata = new ClassMetadata
        {
            Mode = CaptureMode.Online,
            CaptureScope = CaptureScope.Application,
            AudioFormat = PcmWaveFile.MasterAudioFormatName,
            FormatVersion = 2,
            AudioManifestReference = new AudioManifestReference(),
        };

        var json = JsonSerializer.Serialize(metadata);
        var decoded = JsonSerializer.Deserialize<ClassMetadata>(json)!;

        StringAssert.Contains(json, "\"audioManifestReference\"");
        StringAssert.Contains(json, "\"relativePath\":\"audio-manifest.json\"");
        Assert.DoesNotContain("Clase online", json);
        Assert.AreEqual(PcmWaveFile.MasterAudioFormatName, decoded.AudioFormat);
        Assert.AreEqual("audio-manifest.json", decoded.AudioManifestReference?.RelativePath);
    }

    private (string Folder, string Master, string Manifest) CreateOnlineMaster(
        int sampleRate,
        int channels,
        int frames)
    {
        var folder = Path.Combine(temporaryRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var master = Path.Combine(folder, "master.raw");
        var manifest = Path.Combine(folder, "audio-manifest.json");
        WriteManifestAndMaster(manifest, master, sampleRate, channels, new float[frames * channels]);
        return (folder, master, manifest);
    }

    private static void WriteManifestAndMaster(
        string manifestPath,
        string masterPath,
        int sampleRate,
        int channels,
        float[] samples)
    {
        AudioManifestFile.WriteAtomic(
            manifestPath,
            new AudioManifest
            {
                Master = new AudioManifestMaster
                {
                    SampleRate = sampleRate,
                    Channels = channels,
                },
            });
        File.WriteAllBytes(masterPath, PcmAudioConverter.EncodeFloat32LE(samples));
    }
}
