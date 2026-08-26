using ClassScribe.Core;
using ClassScribe.Windows;
using NAudio.CoreAudioApi;

namespace ClassScribe.Windows.Tests;

[TestClass]
public sealed class MainViewModelSystemOutputConsentTests
{
    [TestMethod]
    public async Task selectingSystemOutputDoesNotAuthorizeOrStart()
    {
        var promptCalls = 0;
        var (model, factory, root) = NewModel(() =>
        {
            promptCalls++;
            return true;
        });
        try
        {
            SelectSystemOutput(model);

            Assert.IsTrue(model.CanStart);
            Assert.AreEqual(0, promptCalls);
            Assert.AreEqual(0, factory.SystemBuildCount);
            Assert.IsFalse(Directory.Exists(root));
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task deniedPromptDoesNotStartCaptureOrCreateRaw()
    {
        var promptCalls = 0;
        var (model, factory, root) = NewModel(() =>
        {
            promptCalls++;
            return false;
        });
        try
        {
            SelectSystemOutput(model);
            await model.StartAsync();

            Assert.AreEqual(1, promptCalls);
            Assert.AreEqual(0, factory.SystemBuildCount);
            Assert.IsNull(model.PendingSystemOutputConsent);
            Assert.IsFalse(model.IsRecording);
            Assert.IsFalse(Directory.Exists(root));
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task acceptedPromptPassesAuthorizationForSameAttemptAndPersistsScope()
    {
        var (model, factory, root) = NewModel(() => true);
        try
        {
            SelectSystemOutput(model);
            await model.StartAsync();

            Assert.AreEqual(1, factory.SystemBuildCount);
            Assert.IsTrue(model.IsRecording);
            Assert.IsNotNull(model.CurrentFolder);
            var summary = new SessionStore(root).ScanSessions().Single();
            Assert.AreEqual(CaptureMode.Online, summary.Metadata.Mode);
            Assert.AreEqual(CaptureScope.SystemOutput, summary.Metadata.CaptureScope);
            Assert.AreEqual("Audio del equipo", summary.Metadata.Source);

            await model.StopForExitAsync();
            Assert.IsFalse(model.IsRecording);
            Assert.IsTrue(File.Exists(Path.Combine(summary.Folder, "source.wav")));
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task applicationAndMicrophoneStartsNeverInvokeSystemOutputConsent()
    {
        var promptCalls = 0;
        var (model, _, root) = NewModel(() =>
        {
            promptCalls++;
            return true;
        });
        try
        {
            model.SelectedSource = new AudioSourceOption(
                AudioSourceKind.Process,
                "synthetic-process",
                "Synthetic app",
                ProcessId: Environment.ProcessId);
            await model.StartAsync();
            Assert.AreEqual(0, promptCalls);

            model.SelectedMode = model.CaptureModes.Single(mode => mode.Value == CaptureMode.InPerson);
            model.SelectedSource = new AudioSourceOption(
                AudioSourceKind.Microphone,
                "synthetic-microphone",
                "Synthetic microphone");
            await model.StartAsync();
            Assert.AreEqual(0, promptCalls);
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task applicationFailureCtaOnlySelectsSystemOutputAndDoesNotStartIt()
    {
        var (model, factory, root) = NewModel(() => true);
        try
        {
            model.SelectedSource = new AudioSourceOption(
                AudioSourceKind.Process,
                "synthetic-process",
                "Synthetic app",
                ProcessId: Environment.ProcessId);
            await model.StartAsync();

            Assert.IsTrue(model.ShowSystemOutputRecovery);
            Assert.AreEqual(0, factory.SystemBuildCount);
            model.SelectSystemOutputAfterApplicationFailure();

            Assert.AreEqual(OnlineCaptureSource.SystemOutput, model.SelectedOnlineSource.Value);
            Assert.IsTrue(model.CanStart);
            Assert.IsFalse(model.IsRecording);
            Assert.AreEqual(0, factory.SystemBuildCount);
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task changingSourceWhileConsentIsVisibleInvalidatesTheStaleAttempt()
    {
        MainViewModel? model = null;
        var promptCalls = 0;
        var root = NewRoot();
        var factory = new ConsentWindowsAudioCaptureFactory();
        var capture = new WindowsAudioCapture(factory);
        model = new MainViewModel(
            new SessionStore(root),
            capture,
            () =>
            {
                promptCalls++;
                model!.SelectedOnlineSource = model.OnlineSourceChoices.Single(choice =>
                    choice.Value == OnlineCaptureSource.Application);
                return true;
            });
        model.Subject = "Álgebra";
        SelectSystemOutput(model);
        try
        {
            await model.StartAsync();

            Assert.AreEqual(1, promptCalls);
            Assert.IsNull(model.PendingSystemOutputConsent);
            Assert.AreEqual(0, factory.SystemBuildCount);
            Assert.IsFalse(Directory.Exists(root));
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task everyNewSystemOutputStartShowsConsentAgain()
    {
        var promptCalls = 0;
        var (model, factory, root) = NewModel(() => ++promptCalls == 1);
        try
        {
            SelectSystemOutput(model);
            await model.StartAsync();
            Assert.IsTrue(model.IsRecording);
            await model.StopForExitAsync();

            await model.StartAsync();

            Assert.AreEqual(2, promptCalls);
            Assert.AreEqual(1, factory.SystemBuildCount);
            Assert.IsFalse(model.IsRecording);
            Assert.IsNull(model.PendingSystemOutputConsent);
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    private static (MainViewModel Model, ConsentWindowsAudioCaptureFactory Factory, string Root) NewModel(
        Func<bool> prompt)
    {
        var root = NewRoot();
        var factory = new ConsentWindowsAudioCaptureFactory();
        var capture = new WindowsAudioCapture(factory);
        var model = new MainViewModel(new SessionStore(root), capture, prompt);
        model.Subject = "Álgebra";
        return (model, factory, root);
    }

    private static void SelectSystemOutput(MainViewModel model) =>
        model.SelectedOnlineSource = model.OnlineSourceChoices.Single(choice =>
            choice.Value == OnlineCaptureSource.SystemOutput);

    private static string NewRoot()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "ClassScribe.Windows.Tests",
            Guid.NewGuid().ToString("N"));
        return root;
    }

    private static void DeleteFolder(string folder)
    {
        if (Directory.Exists(folder))
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    private sealed class ConsentWindowsAudioCaptureFactory : IWindowsAudioCaptureFactory
    {
        private int systemBuildCount;

        public int SystemBuildCount => Volatile.Read(ref systemBuildCount);

        public WindowsRenderEndpoint GetDefaultRenderEndpoint() =>
            new("render-consent", null);

        public string GetDefaultRenderEndpointId() => "render-consent";

        public Task<IWindowsAudioRecorder> BuildProcessLoopbackRecorderAsync(
            uint rootProcessId,
            CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public IWindowsAudioRecorder BuildSystemOutputRecorder(WindowsRenderEndpoint endpoint)
        {
            Interlocked.Increment(ref systemBuildCount);
            return new ConsentWindowsAudioRecorder();
        }

        public MMDevice GetDevice(string deviceId) => throw new NotSupportedException();

        public IWindowsAudioRecorder BuildDeviceRecorder(MMDevice device) =>
            throw new NotSupportedException();
    }

    private sealed class ConsentWindowsAudioRecorder : IWindowsAudioRecorder
    {
        public event Action<ReadOnlyMemory<byte>>? DataAvailable;

        public event Action<Exception?>? RecordingStopped;

        public AudioPcmFormat Format { get; } = AudioPcmFormat.Create(
            48_000,
            2,
            AudioSampleEncoding.Float32LE);

        public void StartRecording() =>
            DataAvailable?.Invoke(new byte[] { 1, 0, 1, 0, 1, 0, 1, 0 });

        public void StopRecording() => RecordingStopped?.Invoke(null);

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
