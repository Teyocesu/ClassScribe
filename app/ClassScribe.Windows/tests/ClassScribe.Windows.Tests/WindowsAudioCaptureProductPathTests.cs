using ClassScribe.Core;
using ClassScribe.Windows;
using NAudio.CoreAudioApi;

namespace ClassScribe.Windows.Tests;

[TestClass]
public sealed class WindowsAudioCaptureProductPathTests
{
    [TestMethod]
    public async Task nullAuthorizationRejectedBeforeRawCreation()
    {
        var factory = new FakeWindowsAudioCaptureFactory();
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();

        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            capture.StartAsync(SystemSource(), folder, attempt, CancellationToken.None));

        Assert.IsFalse(File.Exists(Path.Combine(folder, "master.raw")));
        Assert.IsFalse(File.Exists(Path.Combine(folder, "audio-manifest.json")));
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task systemOutputUsesRenderLoopbackFactory()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();

        await StartSystemOutputAsync(capture, folder, attempt);

        Assert.AreEqual(1, factory.SystemBuildCount);
        Assert.AreEqual("render-a", factory.BuiltEndpointIDs.Single());
        Assert.AreEqual("render-a", capture.ActiveRenderEndpointIDForTest);

        await capture.StopAsync(CancellationToken.None);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task sameEndpointDoesNotRebuild()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        Assert.IsFalse(await capture.ProbeSystemOutputForTestAsync(attempt));
        Assert.AreEqual(1, factory.SystemBuildCount);

        await capture.StopAsync(CancellationToken.None);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task endpointChangeRunsSingleRebind()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        factory.CurrentEndpointID = "render-b";
        Assert.IsTrue(await capture.ProbeSystemOutputForTestAsync(attempt));
        Assert.AreEqual(2, factory.SystemBuildCount);
        Assert.AreEqual("render-b", capture.ActiveRenderEndpointIDForTest);

        Assert.IsFalse(await capture.ProbeSystemOutputForTestAsync(attempt));
        Assert.AreEqual(2, factory.SystemBuildCount);

        await capture.StopAsync(CancellationToken.None);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task oldCallbackDrainedBeforeGenerationAdvance()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        factory.CurrentEndpointID = "render-b";
        Assert.IsTrue(await capture.ProbeSystemOutputForTestAsync(attempt));

        CollectionAssert.AreEqual(
            new[] { "stop", "dispose", "build" },
            factory.LifecycleEvents.TakeLast(3).ToArray());

        await capture.StopAsync(CancellationToken.None);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task endpointRebindKeepsSameRawWriter()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        factory.CurrentEndpointID = "render-b";
        Assert.IsTrue(await capture.ProbeSystemOutputForTestAsync(attempt));
        var wavePath = await capture.StopAsync(CancellationToken.None);

        Assert.IsTrue(File.Exists(wavePath));
        Assert.IsTrue(new FileInfo(wavePath).Length > 44, "Both generations must append to the durable session stream.");
        Assert.IsTrue(File.Exists(Path.Combine(folder, "master.raw")));
        Assert.IsTrue(File.Exists(Path.Combine(folder, "audio-manifest.json")));
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task stopDuringSystemOutputSourceLessWindowFinalizesExistingAudio()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        factory.CurrentEndpointID = "render-b";
        factory.BlockNextSystemBuild = true;
        var rebindTask = capture.ProbeSystemOutputForTestAsync(attempt);
        Assert.IsTrue(factory.BuildEntered.Wait(TimeSpan.FromSeconds(3)));

        var stopTask = capture.StopAsync(CancellationToken.None);
        factory.ReleaseBuild.Set();
        var wavePath = await stopTask;
        Assert.IsFalse(await rebindTask);

        Assert.IsTrue(File.Exists(wavePath));
        Assert.IsFalse(capture.IsRecording);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task stopDuringSystemOutputBuildCannotPublishRecorderAfterStop()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        factory.CurrentEndpointID = "render-b";
        factory.BlockNextSystemBuild = true;
        var rebindTask = capture.ProbeSystemOutputForTestAsync(attempt);
        Assert.IsTrue(factory.BuildEntered.Wait(TimeSpan.FromSeconds(3)));

        var stopTask = capture.StopAsync(CancellationToken.None);
        factory.ReleaseBuild.Set();
        await stopTask;
        Assert.IsFalse(await rebindTask);
        Assert.AreEqual(0, factory.Recorders[1].StartCount);

        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task sourceLessRebindDoesNotAllowSecondStart()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var secondFolder = NewFolder();
        var attempt = NewAttempt();
        var secondAttempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        factory.CurrentEndpointID = "render-b";
        factory.BlockNextSystemBuild = true;
        var rebindTask = capture.ProbeSystemOutputForTestAsync(attempt);
        Assert.IsTrue(factory.BuildEntered.Wait(TimeSpan.FromSeconds(3)));

        var authorization = capture.IssueSystemOutputAuthorizationAfterExplicitUserConsent(secondAttempt);
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            capture.StartAsync(
                SystemSource(),
                secondFolder,
                secondAttempt,
                CancellationToken.None,
                authorization));

        var stopTask = capture.StopAsync(CancellationToken.None);
        factory.ReleaseBuild.Set();
        await stopTask;
        Assert.IsFalse(await rebindTask);
        DeleteFolder(folder);
        DeleteFolder(secondFolder);
    }

    [TestMethod]
    public async Task failedEndpointRebindStillAllowsStopAndRecovery()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var recoveryFolder = NewFolder();
        var attempt = NewAttempt();
        var recoveryAttempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        factory.CurrentEndpointID = "render-b";
        factory.FailNextSystemBuild = true;
        Assert.IsFalse(await capture.ProbeSystemOutputForTestAsync(attempt));
        Assert.IsTrue(capture.IsRecording, "Session ownership must survive a source-less failed rebind.");

        await capture.StopAsync(CancellationToken.None);
        var recoveryAuthorization = capture.IssueSystemOutputAuthorizationAfterExplicitUserConsent(recoveryAttempt);
        await capture.StartAsync(
            SystemSource(),
            recoveryFolder,
            recoveryAttempt,
            CancellationToken.None,
            recoveryAuthorization);
        Assert.IsTrue(capture.IsRecording);
        await capture.StopAsync(CancellationToken.None);

        DeleteFolder(folder);
        DeleteFolder(recoveryFolder);
    }

    [TestMethod]
    public async Task concurrentStopCallsShareOneFinalization()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        var finalization = new FinalizationGate();
        capture.SetFinalizationHookForTest(finalization.BlockAsync);
        var firstStop = capture.StopAsync(CancellationToken.None);
        await finalization.Entered.Task;
        var secondStop = capture.StopAsync(CancellationToken.None);

        finalization.Release.TrySetResult(true);
        var paths = await Task.WhenAll(firstStop, secondStop);

        Assert.AreEqual(paths[0], paths[1]);
        Assert.AreEqual(1, finalization.InvocationCount);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task concurrentStopFollowersReceiveSameWavePath()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        var finalization = new FinalizationGate();
        capture.SetFinalizationHookForTest(finalization.BlockAsync);
        var stops = new[]
        {
            capture.StopAsync(CancellationToken.None),
        };
        await finalization.Entered.Task;
        var allStops = stops
            .Append(capture.StopAsync(CancellationToken.None))
            .Append(capture.StopAsync(CancellationToken.None))
            .ToArray();

        finalization.Release.TrySetResult(true);
        var paths = await Task.WhenAll(allStops);

        Assert.IsTrue(paths.All(path => path == paths[0]));
        Assert.IsTrue(File.Exists(paths[0]));
        Assert.AreEqual(1, finalization.InvocationCount);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task concurrentStopDoesNotDoubleDisposeRawWriter()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var attempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        var recorder = factory.Recorders.Single();
        var finalization = new FinalizationGate();
        capture.SetFinalizationHookForTest(finalization.BlockAsync);
        var firstStop = capture.StopAsync(CancellationToken.None);
        await finalization.Entered.Task;
        var secondStop = capture.StopAsync(CancellationToken.None);
        finalization.Release.TrySetResult(true);
        await Task.WhenAll(firstStop, secondStop);

        Assert.AreEqual(1, recorder.DisposeCount);
        Assert.AreEqual(1, finalization.InvocationCount);
        DeleteFolder(folder);
    }

    [TestMethod]
    public async Task startRejectedWhileStopFinalizationIsInProgress()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var secondFolder = NewFolder();
        var attempt = NewAttempt();
        var secondAttempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        var finalization = new FinalizationGate();
        capture.SetFinalizationHookForTest(finalization.BlockAsync);
        var stop = capture.StopAsync(CancellationToken.None);
        await finalization.Entered.Task;

        var authorization = capture.IssueSystemOutputAuthorizationAfterExplicitUserConsent(secondAttempt);
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            capture.StartAsync(
                SystemSource(),
                secondFolder,
                secondAttempt,
                CancellationToken.None,
                authorization));

        finalization.Release.TrySetResult(true);
        await stop;
        DeleteFolder(folder);
        DeleteFolder(secondFolder);
    }

    [TestMethod]
    public async Task nextStartAllowedAfterStopFinalizationCompletes()
    {
        var factory = new FakeWindowsAudioCaptureFactory { CurrentEndpointID = "render-a" };
        await using var capture = new WindowsAudioCapture(factory);
        var folder = NewFolder();
        var secondFolder = NewFolder();
        var attempt = NewAttempt();
        var secondAttempt = NewAttempt();
        await StartSystemOutputAsync(capture, folder, attempt);

        var finalization = new FinalizationGate();
        capture.SetFinalizationHookForTest(finalization.BlockAsync);
        var firstStop = capture.StopAsync(CancellationToken.None);
        await finalization.Entered.Task;
        finalization.Release.TrySetResult(true);
        var firstWavePath = await firstStop;

        Assert.IsTrue(File.Exists(firstWavePath));
        Assert.IsFalse(capture.IsRecording);
        await StartSystemOutputAsync(capture, secondFolder, secondAttempt);
        Assert.IsTrue(capture.IsRecording);
        var secondWavePath = await capture.StopAsync(CancellationToken.None);

        Assert.IsTrue(File.Exists(secondWavePath));
        Assert.AreEqual(2, finalization.InvocationCount);
        DeleteFolder(folder);
        DeleteFolder(secondFolder);
    }

    [TestMethod]
    public async Task processLoopbackBuiltRecorderIsDisposedWhenCancellationWinsAfterBuild()
    {
        var recorder = new FakeWindowsAudioRecorder(new List<string>());
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsExceptionAsync<OperationCanceledException>(async () =>
        {
            await WindowsAudioRecorderOwnership.AdoptBuiltRecorderAsync(
                recorder,
                static candidate => candidate.DisposeAsync(),
                cancellation.Token);
        });

        Assert.AreEqual(1, recorder.DisposeCount);
    }

    [TestMethod]
    public void recorderFormatReflectsRequestedProcessLoopbackContract()
    {
        var requested = ProcessLoopbackFormatPolicy.FromObservedRenderMix(
            AudioPcmFormat.Create(96_000, 1, AudioSampleEncoding.Float32LE));
        var effective = NAudioWindowsAudioRecorder.ToPcmFormat(
            NAudioWindowsAudioCaptureFactory.ToWaveFormat(requested));

        Assert.AreEqual(requested, effective);
    }

    private static async Task StartSystemOutputAsync(
        WindowsAudioCapture capture,
        string folder,
        SessionAttemptID attempt)
    {
        var authorization = capture.IssueSystemOutputAuthorizationAfterExplicitUserConsent(attempt);
        await capture.StartAsync(
            SystemSource(),
            folder,
            attempt,
            CancellationToken.None,
            authorization);
    }

    private static AudioSourceOption SystemSource() => new(
        AudioSourceKind.SystemOutput,
        "system-output",
        "System output");

    private static SessionAttemptID NewAttempt() => SessionAttemptID.Create(Guid.NewGuid(), 1);

    private static string NewFolder()
    {
        var folder = Path.Combine(Path.GetTempPath(), "ClassScribe.Windows.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }

    private static void DeleteFolder(string folder)
    {
        if (Directory.Exists(folder))
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    private sealed class FakeWindowsAudioCaptureFactory : IWindowsAudioCaptureFactory
    {
        private readonly object sync = new();
        private int systemBuildCount;

        public string CurrentEndpointID { get; set; } = "render-a";

        public bool BlockNextSystemBuild { get; set; }

        public bool FailNextSystemBuild { get; set; }

        public ManualResetEventSlim BuildEntered { get; } = new(false);

        public ManualResetEventSlim ReleaseBuild { get; } = new(false);

        public List<FakeWindowsAudioRecorder> Recorders { get; } = [];

        public List<string> BuiltEndpointIDs { get; } = [];

        public List<string> LifecycleEvents { get; } = [];

        public int SystemBuildCount
        {
            get
            {
                lock (sync)
                {
                    return systemBuildCount;
                }
            }
        }

        public WindowsRenderEndpoint GetDefaultRenderEndpoint() =>
            new(CurrentEndpointID, null);

        public string GetDefaultRenderEndpointId() => CurrentEndpointID;

        public Task<IWindowsAudioRecorder> BuildProcessLoopbackRecorderAsync(
            uint rootProcessId,
            CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public IWindowsAudioRecorder BuildSystemOutputRecorder(WindowsRenderEndpoint endpoint)
        {
            lock (sync)
            {
                systemBuildCount++;
                BuiltEndpointIDs.Add(endpoint.EndpointId);
                LifecycleEvents.Add("build");
            }

            if (BlockNextSystemBuild)
            {
                BlockNextSystemBuild = false;
                BuildEntered.Set();
                ReleaseBuild.Wait(TimeSpan.FromSeconds(5));
            }

            if (FailNextSystemBuild)
            {
                FailNextSystemBuild = false;
                throw new IOException("synthetic endpoint build failure");
            }

            var recorder = new FakeWindowsAudioRecorder(LifecycleEvents);
            Recorders.Add(recorder);
            return recorder;
        }

        public MMDevice GetDevice(string deviceId) => throw new NotSupportedException();

        public IWindowsAudioRecorder BuildDeviceRecorder(MMDevice device) =>
            throw new NotSupportedException();
    }

    private sealed class FakeWindowsAudioRecorder : IWindowsAudioRecorder
    {
        private readonly List<string> lifecycleEvents;

        public FakeWindowsAudioRecorder(List<string> lifecycleEvents)
        {
            this.lifecycleEvents = lifecycleEvents;
        }

        public event Action<ReadOnlyMemory<byte>>? DataAvailable;

        public event Action<Exception?>? RecordingStopped;

        public AudioPcmFormat Format { get; } = AudioPcmFormat.Create(
            48_000,
            2,
            AudioSampleEncoding.Float32LE);

        public int StartCount { get; private set; }

        private int disposeCount;

        public int DisposeCount => Volatile.Read(ref disposeCount);

        public void StartRecording()
        {
            StartCount++;
            DataAvailable?.Invoke(new byte[] { 1, 0, 1, 0, 1, 0, 1, 0 });
        }

        public void StopRecording()
        {
            lifecycleEvents.Add("stop");
            RecordingStopped?.Invoke(null);
        }

        public ValueTask DisposeAsync()
        {
            Interlocked.Increment(ref disposeCount);
            lifecycleEvents.Add("dispose");
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FinalizationGate
    {
        private int invocationCount;

        public TaskCompletionSource<bool> Entered { get; } = NewSignal();

        public TaskCompletionSource<bool> Release { get; } = NewSignal();

        public int InvocationCount => Volatile.Read(ref invocationCount);

        public Task BlockAsync(string _, CancellationToken __)
        {
            Interlocked.Increment(ref invocationCount);
            Entered.TrySetResult(true);
            return Release.Task;
        }

        private static TaskCompletionSource<bool> NewSignal() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}
