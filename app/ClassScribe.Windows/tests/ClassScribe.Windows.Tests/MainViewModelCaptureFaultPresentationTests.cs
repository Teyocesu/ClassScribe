using ClassScribe.Core;
using ClassScribe.Windows;
using NAudio.CoreAudioApi;

namespace ClassScribe.Windows.Tests;

[TestClass]
public sealed class MainViewModelCaptureFaultPresentationTests
{
    [TestMethod]
    public async Task sourceFaultPresentationSurvivesSignalLiveAndModelUpdates()
    {
        var rig = NewRig();
        try
        {
            await rig.Model.StartAsync();

            Assert.IsTrue(rig.Model.IsRecording);
            rig.Recorder.RaiseRecordingStopped(new IOException("source unavailable"));

            var warning = rig.Model.WarningText;
            var status = rig.Model.StatusText;
            Assert.IsTrue(warning.Contains("La fuente de audio se interrumpió", StringComparison.Ordinal));
            StringAssert.Contains(status, "Detén la sesión para validar");
            Assert.IsFalse(rig.Model.ShowSystemOutputRecovery);

            rig.Clock.NowSeconds = 13;
            var signal = rig.Capture.EvaluateSignalHealth(rig.Attempt);

            Assert.AreEqual(CaptureSignalState.NoCallbacks, signal?.State);
            Assert.AreEqual(CaptureSignalState.NoCallbacks, rig.Model.SignalState);
            Assert.AreEqual(warning, rig.Model.WarningText);
            Assert.AreEqual(status, rig.Model.StatusText);

            rig.Model.PublishLiveTextForTest("texto en vivo posterior al fallo");
            Assert.AreEqual(warning, rig.Model.WarningText);
            Assert.AreEqual(status, rig.Model.StatusText);

            rig.Model.UpdateModelProgressForTest(new ModelDownloadProgress("Whisper", 1, 10));
            Assert.AreEqual(0.1, rig.Model.ModelProgress, 0.0001);
            Assert.AreEqual(warning, rig.Model.WarningText);
            Assert.AreEqual(status, rig.Model.StatusText);

            await rig.Model.StopForExitAsync();
            Assert.IsFalse(rig.Model.IsRecording);
            Assert.IsTrue(rig.Model.ShowSystemOutputRecovery);
            StringAssert.Contains(rig.Model.StatusText, "Audio y texto guardados");
        }
        finally
        {
            await DisposeAsync(rig);
        }
    }

    [TestMethod]
    public async Task durableMasterAndStorageFaultsRemainTerminalWithoutSystemOutputSuggestion()
    {
        foreach (var category in new[]
                 {
                     CaptureFailureCategory.DurableMaster,
                     CaptureFailureCategory.Storage,
                 })
        {
            var rig = NewRig();
            try
            {
                await rig.Model.StartAsync();

                rig.Model.ApplyCaptureFaultForTest(new CaptureFault(
                    new IOException($"synthetic {category} failure"),
                    category));

                var warning = rig.Model.WarningText;
                var status = rig.Model.StatusText;
                Assert.IsTrue(rig.Model.IsRecording);
                Assert.IsFalse(rig.Model.ShowSystemOutputRecovery);

                rig.Model.PublishLiveTextForTest("texto posterior al fallo durable");
                rig.Model.UpdateModelProgressForTest(new ModelDownloadProgress("Modelo", 5, 10));

                Assert.AreEqual(warning, rig.Model.WarningText);
                Assert.AreEqual(status, rig.Model.StatusText);
                Assert.AreEqual(0.5, rig.Model.ModelProgress, 0.0001);
            }
            finally
            {
                await DisposeAsync(rig);
            }
        }
    }

    [TestMethod]
    public async Task newStartClearsPreviousTerminalCaptureFaultPresentation()
    {
        var rig = NewRig();
        try
        {
            await rig.Model.StartAsync();
            rig.Recorder.RaiseRecordingStopped(new IOException("source unavailable"));
            Assert.IsFalse(rig.Model.ShowSystemOutputRecovery);

            await rig.Model.StopForExitAsync();
            Assert.IsTrue(rig.Model.ShowSystemOutputRecovery);
            await rig.Model.StartAsync();

            Assert.IsTrue(rig.Model.IsRecording);
            rig.Model.PublishLiveTextForTest("nuevo intento");
            Assert.AreEqual(string.Empty, rig.Model.WarningText);
            Assert.AreEqual("Grabando y transcribiendo", rig.Model.StatusText);
        }
        finally
        {
            await DisposeAsync(rig);
        }
    }

    private static TestRig NewRig()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "ClassScribe.Windows.Tests",
            Guid.NewGuid().ToString("N"));
        var clock = new TestClock();
        var identity = WindowsApplicationIdentity.FromObservation(
            @"C:\ClassScribeSourceFixture\ClassScribeSourceFixture.exe",
            "ClassScribeSourceFixture");
        var factory = new PresentationCaptureFactory();
        var capture = new WindowsAudioCapture(
            factory,
            clock,
            () => [new WindowsProcessIncarnation(42_001, identity)]);
        var model = new MainViewModel(
            new SessionStore(root),
            capture,
            () => true,
            prepareTranscription: static (_, _) => Task.CompletedTask)
        {
            Subject = "Presentación de fallos",
            SelectedSource = new AudioSourceOption(
                AudioSourceKind.Process,
                "synthetic-process",
                "Synthetic app",
                42_001,
                identity),
        };
        var rig = new TestRig(root, model, capture, factory, clock);
        capture.SignalHealthChanged += rig.ObserveAttempt;
        return rig;
    }

    private static async Task DisposeAsync(TestRig rig)
    {
        await rig.Model.DisposeAsync();
        if (Directory.Exists(rig.Root))
        {
            Directory.Delete(rig.Root, recursive: true);
        }
    }

    private sealed class TestRig
    {
        public TestRig(
            string root,
            MainViewModel model,
            WindowsAudioCapture capture,
            PresentationCaptureFactory factory,
            TestClock clock)
        {
            Root = root;
            Model = model;
            Capture = capture;
            Factory = factory;
            Clock = clock;
        }

        public string Root { get; }

        public MainViewModel Model { get; }

        public WindowsAudioCapture Capture { get; }

        public PresentationCaptureFactory Factory { get; }

        public TestClock Clock { get; }

        public PresentationRecorder Recorder => Factory.CurrentRecorder
            ?? throw new InvalidOperationException("El recorder de prueba no fue construido.");

        public SessionAttemptID Attempt { get; private set; } = null!;

        public void ObserveAttempt(SessionAttemptID attempt, CaptureSignalHealthSnapshot _) =>
            Attempt ??= attempt;
    }

    private sealed class TestClock : IMonotonicClock
    {
        public double NowSeconds { get; set; }
    }

    private sealed class PresentationCaptureFactory : IWindowsAudioCaptureFactory
    {
        public PresentationRecorder? CurrentRecorder { get; private set; }

        public WindowsRenderEndpoint GetDefaultRenderEndpoint() =>
            new("render-presentation", null);

        public string GetDefaultRenderEndpointId() => "render-presentation";

        public Task<IWindowsAudioRecorder> BuildProcessLoopbackRecorderAsync(
            uint rootProcessId,
            CancellationToken cancellationToken)
        {
            CurrentRecorder = new PresentationRecorder();
            return Task.FromResult<IWindowsAudioRecorder>(CurrentRecorder);
        }

        public IWindowsAudioRecorder BuildSystemOutputRecorder(WindowsRenderEndpoint endpoint) =>
            throw new NotSupportedException();

        public MMDevice GetDevice(string deviceId) => throw new NotSupportedException();

        public IWindowsAudioRecorder BuildDeviceRecorder(MMDevice device) =>
            throw new NotSupportedException();
    }

    private sealed class PresentationRecorder : IWindowsAudioRecorder
    {
        public event Action<ReadOnlyMemory<byte>>? DataAvailable;

        public event Action<Exception?>? RecordingStopped;

        public AudioPcmFormat Format { get; } = AudioPcmFormat.Create(
            48_000,
            2,
            AudioSampleEncoding.Float32LE);

        public void StartRecording() => DataAvailable?.Invoke(new byte[48]);

        public void StopRecording() => RecordingStopped?.Invoke(null);

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        public void RaiseRecordingStopped(Exception error) => RecordingStopped?.Invoke(error);
    }
}
