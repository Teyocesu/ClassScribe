namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class PersistenceTests
{
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
        Directory.CreateSymbolicLink(linkedSession, outside);
        var store = new SessionStore(sessionsRoot);

        await Assert.ThrowsExactlyAsync<UnauthorizedAccessException>(
            () => store.SaveMetadataAsync(new ClassMetadata { Subject = "Privada" }, linkedSession));
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
}
