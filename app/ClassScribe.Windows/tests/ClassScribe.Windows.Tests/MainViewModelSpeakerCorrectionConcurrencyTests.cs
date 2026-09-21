using System.Text.Json;
using ClassScribe.Core;
using ClassScribe.Windows;

namespace ClassScribe.Windows.Tests;

[TestClass]
public sealed class MainViewModelSpeakerCorrectionConcurrencyTests
{
    private static readonly JsonSerializerOptions OverlayJsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly string[] ExpectedRapidCorrectionNames = ["Primero", "Segundo"];

    [TestMethod]
    public async Task lateCorrectionFromSessionAIsPersistedOnlyToA()
    {
        var root = NewRoot();
        var store = new BlockingSessionStore(root);
        var model = NewModel(store);
        try
        {
            var sessionA = await CreateSessionAsync(store, "Sesión A", DateTimeOffset.UtcNow.AddMinutes(-2));
            var sessionB = await CreateSessionAsync(store, "Sesión B", DateTimeOffset.UtcNow.AddMinutes(-1));
            await OpenSessionAsync(model, sessionA.Summary);

            model.SelectedSpeaker = model.Speakers.Single();
            model.SpeakerNameDraft = "A corregido";
            store.BlockNextFinalSave();
            var correction = model.RenameSelectedSpeakerAsync();
            await store.SaveStarted.Task.ConfigureAwait(false);

            await OpenSessionAsync(model, sessionB.Summary);
            store.ReleaseBlockedSave();
            await correction.ConfigureAwait(false);

            Assert.AreEqual(sessionB.Folder, model.CurrentFolder);
            Assert.AreEqual("Persona 1", model.Speakers.Single().Model.DisplayName);
            var overlayA = ReadOverlay(sessionA.Folder);
            Assert.IsTrue(overlayA.Operations.Any(operation => operation.DisplayName == "A corregido"));
            Assert.IsFalse(File.Exists(Path.Combine(sessionB.Folder, "human-correction-overlay.json")));
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task rapidCorrectionsArePersistedInRequestOrder()
    {
        var root = NewRoot();
        var store = new BlockingSessionStore(root);
        var model = NewModel(store);
        try
        {
            var session = await CreateSessionAsync(store, "Orden", DateTimeOffset.UtcNow);
            await OpenSessionAsync(model, session.Summary);

            model.SelectedSpeaker = model.Speakers.Single();
            model.SpeakerNameDraft = "Primero";
            store.BlockNextFinalSave();
            var first = model.RenameSelectedSpeakerAsync();
            await store.SaveStarted.Task.ConfigureAwait(false);

            model.SpeakerNameDraft = "Segundo";
            var second = model.RenameSelectedSpeakerAsync();
            store.ReleaseBlockedSave();
            await Task.WhenAll(first, second).ConfigureAwait(false);

            var overlay = ReadOverlay(session.Folder);
            var names = overlay.Operations
                .Where(operation => operation.Kind == SpeakerCorrectionKind.Rename)
                .Select(operation => operation.DisplayName)
                .ToArray();
            CollectionAssert.AreEqual(ExpectedRapidCorrectionNames, names);
            Assert.AreEqual("Segundo", model.Speakers.Single().Model.DisplayName);
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task professorSelectionWaitingOnGateDoesNotRetargetToOpenedSession()
    {
        var root = NewRoot();
        var store = new BlockingSessionStore(root);
        var model = NewModel(store);
        try
        {
            var sessionA = await CreateSessionAsync(store, "Materia A", DateTimeOffset.UtcNow.AddMinutes(-2));
            var sessionB = await CreateSessionAsync(store, "Materia B", DateTimeOffset.UtcNow.AddMinutes(-1));
            await OpenSessionAsync(model, sessionA.Summary);

            await model.ApplyProfessorSelectionAsync().ConfigureAwait(false);
            Assert.IsTrue(File.Exists(Path.Combine(sessionA.Folder, "human-correction-overlay.json")));

            model.SpeakerNameDraft = "Tarde";
            store.BlockNextFinalSave();
            var correction = model.RenameSelectedSpeakerAsync();
            await store.SaveStarted.Task.ConfigureAwait(false);

            var professorSelection = model.ApplyProfessorSelectionAsync();
            await OpenSessionAsync(model, sessionB.Summary);
            store.ClearSavedFolders();
            store.ReleaseBlockedSave();
            await Task.WhenAll(correction, professorSelection).ConfigureAwait(false);

            Assert.IsFalse(store.SavedFolders.Contains(sessionB.Folder));
            Assert.IsFalse(File.Exists(Path.Combine(sessionB.Folder, "human-correction-overlay.json")));
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    [TestMethod]
    public async Task saveEditsWaitingOnGateDoesNotRetargetToOpenedSession()
    {
        var root = NewRoot();
        var store = new BlockingSessionStore(root);
        var model = NewModel(store);
        try
        {
            var sessionA = await CreateSessionAsync(store, "Materia A", DateTimeOffset.UtcNow.AddMinutes(-2));
            var sessionB = await CreateSessionAsync(store, "Materia B", DateTimeOffset.UtcNow.AddMinutes(-1));
            await OpenSessionAsync(model, sessionA.Summary);

            await model.SaveEditsAsync().ConfigureAwait(false);
            Assert.IsTrue(store.SavedFolders.Contains(sessionA.Folder));

            model.SpeakerNameDraft = "Tarde";
            store.BlockNextFinalSave();
            var correction = model.RenameSelectedSpeakerAsync();
            await store.SaveStarted.Task.ConfigureAwait(false);

            var save = model.SaveEditsAsync();
            await OpenSessionAsync(model, sessionB.Summary);
            store.ClearSavedFolders();
            store.ReleaseBlockedSave();
            await Task.WhenAll(correction, save).ConfigureAwait(false);

            Assert.IsFalse(store.SavedFolders.Contains(sessionB.Folder));
        }
        finally
        {
            await model.DisposeAsync();
            DeleteFolder(root);
        }
    }

    private static MainViewModel NewModel(SessionStore store) => new(
        store,
        new WindowsAudioCapture(),
        systemOutputConsentPrompt: static () => false,
        prepareTranscription: static (_, _) => Task.CompletedTask);

    private static async Task OpenSessionAsync(MainViewModel model, SessionSummary summary)
    {
        model.SelectedHistory = new HistoryRow(summary);
        await model.LoadSelectedHistoryAsync().ConfigureAwait(false);
    }

    private static async Task<SessionFixture> CreateSessionAsync(
        SessionStore store,
        string subject,
        DateTimeOffset startedAt)
    {
        var folder = store.CreateFolder(subject, startedAt);
        var sessionID = Guid.NewGuid();
        var attempt = SessionAttemptID.Create(sessionID, 1);
        const string speakerID = "speaker-1";
        var segment = new TranscriptSegment
        {
            Start = 0,
            End = 1,
            Text = subject,
            SpeakerID = speakerID,
            Confidence = 0.9,
        };
        var speaker = new SpeakerRecord
        {
            Id = speakerID,
            DisplayName = "Persona 1",
            TotalSpeakingTime = 1,
            Confidence = 0.9,
        };
        var metadata = new ClassMetadata
        {
            Id = sessionID,
            Subject = subject,
            StartedAt = startedAt,
            Duration = 1,
            Mode = CaptureMode.InPerson,
            Source = "Prueba",
            SpeakerCount = 1,
            State = ProcessingState.Complete,
            FolderPath = folder,
            CaptureScope = CaptureScope.Microphone,
            SessionPhase = SessionPhase.Complete,
            CapturePhase = CapturePhase.Idle,
            AsrPhase = AsrPhase.Idle,
            AttemptID = attempt,
        };
        await store.SaveFinalAsync(
                metadata,
                new[] { segment },
                new[] { segment },
                Array.Empty<ReviewItem>(),
                new[] { speaker },
                folder)
            .ConfigureAwait(false);
        return new SessionFixture(folder, store.ScanSessions().Single(summary => summary.Folder == folder));
    }

    private static HumanCorrectionOverlay ReadOverlay(string folder) =>
        JsonSerializer.Deserialize<HumanCorrectionOverlay>(
            File.ReadAllText(Path.Combine(folder, "human-correction-overlay.json")),
            OverlayJsonOptions)
        ?? throw new InvalidDataException("No se pudo leer el overlay de prueba.");

    private static string NewRoot() => Path.Combine(
        Path.GetTempPath(),
        "ClassScribe.Windows.Tests",
        Guid.NewGuid().ToString("N"));

    private static void DeleteFolder(string folder)
    {
        if (Directory.Exists(folder))
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    private sealed record SessionFixture(string Folder, SessionSummary Summary);

    private sealed class BlockingSessionStore(string root) : SessionStore(root)
    {
        private readonly object savedFoldersSync = new();
        private readonly List<string> savedFolders = [];
        private int blockNextSave;
        private TaskCompletionSource<bool>? releaseSave;

        public TaskCompletionSource<bool> SaveStarted { get; private set; } = NewSignal();

        public IReadOnlyList<string> SavedFolders
        {
            get
            {
                lock (savedFoldersSync)
                {
                    return savedFolders.ToArray();
                }
            }
        }

        public void ClearSavedFolders()
        {
            lock (savedFoldersSync)
            {
                savedFolders.Clear();
            }
        }

        public void BlockNextFinalSave()
        {
            SaveStarted = NewSignal();
            releaseSave = NewSignal();
            Interlocked.Exchange(ref blockNextSave, 1);
        }

        public void ReleaseBlockedSave() =>
            (releaseSave ?? throw new InvalidOperationException("No hay una persistencia bloqueada."))
                .TrySetResult(true);

        public override async Task SaveFinalAsync(
            ClassMetadata metadata,
            IReadOnlyList<TranscriptSegment> all,
            IReadOnlyList<TranscriptSegment> professor,
            IReadOnlyList<ReviewItem> review,
            IReadOnlyList<SpeakerRecord> speakers,
            string folder,
            HumanCorrectionUpdate? humanCorrection = null,
            DiarizationProposal? diarizationProposal = null,
            CancellationToken cancellationToken = default)
        {
            lock (savedFoldersSync)
            {
                savedFolders.Add(folder);
            }

            if (Interlocked.Exchange(ref blockNextSave, 0) == 1)
            {
                SaveStarted.TrySetResult(true);
                await (releaseSave ?? throw new InvalidOperationException("Falta la barrera de prueba."))
                    .Task
                    .ConfigureAwait(false);
            }

            await base.SaveFinalAsync(
                    metadata,
                    all,
                    professor,
                    review,
                    speakers,
                    folder,
                    humanCorrection,
                    diarizationProposal,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        private static TaskCompletionSource<bool> NewSignal() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}
