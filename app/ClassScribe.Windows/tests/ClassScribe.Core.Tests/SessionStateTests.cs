using System.Text.Json;
using System.Text.Json.Nodes;
using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class SessionStateTests
{
    [TestMethod]
    public void APreviousGenerationCannotOwnTheCurrentAttempt()
    {
        var sessionID = Guid.NewGuid();
        var first = SessionAttemptID.Create(sessionID, 1);
        var second = SessionAttemptID.Create(sessionID, 2);

        Assert.AreNotEqual(first, second);
        Assert.AreEqual(sessionID, second.SessionID);
        Assert.IsTrue(first.Generation < second.Generation);
        Assert.AreNotEqual(first.Nonce, second.Nonce);
    }

    [TestMethod]
    public void CaptureCallbackLeaseSurvivesStartupAndRecordingThenRejectsStaleEvents()
    {
        var first = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var second = SessionAttemptID.Create(first.SessionID, 2);
        var active = first;
        var callbacksRegistered = true;
        var firstCallbacks = 0;
        var secondCallbacks = 0;
        var firstLease = new SessionAttemptCallbackLease(
            first,
            attempt => callbacksRegistered && active == attempt);
        var secondLease = new SessionAttemptCallbackLease(
            second,
            attempt => callbacksRegistered && active == attempt);
        Action<SessionAttemptID, double> firstLevelCallback = (eventAttempt, _) =>
        {
            if (eventAttempt == firstLease.Attempt)
            {
                firstLease.TryAccept(() => firstCallbacks++);
            }
        };
        Action<SessionAttemptID, double> secondLevelCallback = (eventAttempt, _) =>
        {
            if (eventAttempt == secondLease.Attempt)
            {
                secondLease.TryAccept(() => secondCallbacks++);
            }
        };

        // A callback during startup is accepted, and remains accepted after
        // startup has completed while attempt A is recording.
        firstLevelCallback(first, 0.1);
        Assert.AreEqual(1, firstCallbacks);
        firstLevelCallback(first, 0.5);
        Assert.AreEqual(2, firstCallbacks);

        // Stop/unregister A. A late event must have no effect before B starts.
        firstLease.Revoke();
        callbacksRegistered = false;
        active = null!;
        firstLevelCallback(first, 0.9);

        // B receives its own callbacks, while any late A event remains stale.
        active = second;
        callbacksRegistered = true;
        firstLevelCallback(first, 0.9);
        secondLevelCallback(first, 0.9);
        secondLevelCallback(second, 0.8);

        Assert.AreEqual(2, firstCallbacks);
        Assert.AreEqual(1, secondCallbacks);
    }

    [TestMethod]
    public async Task SuspendedHumanContinuationCannotOverwriteNextAttemptOverlay()
    {
        var first = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var second = SessionAttemptID.Create(first.SessionID, 2);
        var active = first;
        var firstLease = new SessionAttemptCallbackLease(
            first,
            attempt => active == attempt);
        var correctionPreparedByFirstAttempt = new HumanCorrectionUpdate
        {
            AllText = "corrección de A",
            ProfessorText = "profesor de A",
        };
        var overlay = new HumanCorrectionOverlay
        {
            EditedAllText = correctionPreparedByFirstAttempt.AllText,
            EditedProfessorText = correctionPreparedByFirstAttempt.ProfessorText,
        };
        var effectiveStatus = "A en espera";
        var releaseFirstAttempt = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstAttemptSuspended = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var firstContinuation = ContinueFirstAttemptAsync();
        await firstAttemptSuspended.Task;

        // B becomes the owner while A is suspended in its persistence await.
        active = second;
        firstLease.Revoke();
        overlay = new HumanCorrectionOverlay
        {
            EditedAllText = "corrección de B",
            EditedProfessorText = "profesor de B",
        };
        effectiveStatus = "B activa";
        releaseFirstAttempt.SetResult();

        Assert.IsFalse(await firstContinuation);
        Assert.AreEqual("corrección de B", overlay.EditedAllText);
        Assert.AreEqual("profesor de B", overlay.EditedProfessorText);
        Assert.AreEqual("B activa", effectiveStatus);

        async Task<bool> ContinueFirstAttemptAsync()
        {
            // This is the human-edit snapshot taken before A's await.
            var correction = correctionPreparedByFirstAttempt;
            firstAttemptSuspended.SetResult();
            await releaseFirstAttempt.Task;

            return firstLease.TryAccept(() =>
            {
                overlay = overlay with
                {
                    EditedAllText = correction.AllText,
                    EditedProfessorText = correction.ProfessorText,
                };
                effectiveStatus = "A sobrescribió B";
            });
        }
    }

    [TestMethod]
    public void StateAxesSerializeAsStableProductTokens()
    {
        var metadata = new ClassMetadata
        {
            Id = Guid.NewGuid(),
            Subject = "Física",
            Mode = CaptureMode.Online,
            CaptureScope = CaptureScope.Application,
            State = ProcessingState.Complete,
            SessionPhase = SessionPhase.Complete,
            CapturePhase = CapturePhase.Idle,
            AsrPhase = AsrPhase.Idle,
            Language = "fr",
        };

        var json = JsonSerializer.Serialize(metadata);

        StringAssert.Contains(json, "\"schemaVersion\":2");
        StringAssert.Contains(json, "\"captureScope\":\"application\"");
        StringAssert.Contains(json, "\"sessionPhase\":\"complete\"");
        StringAssert.Contains(json, "\"capturePhase\":\"idle\"");
        StringAssert.Contains(json, "\"asrPhase\":\"idle\"");
        StringAssert.Contains(json, "\"transcriptionLanguage\":\"fr\"");
        Assert.DoesNotContain("Transcripción final lista", json);
    }

    [TestMethod]
    public void ExplicitUnknownStateDoesNotBecomeReady()
    {
        var json = MetadataNode();
        json["state"] = "future-state";

        Assert.ThrowsExactly<JsonException>(() => JsonSerializer.Deserialize<ClassMetadata>(json.ToJsonString()));
    }

    [TestMethod]
    public void ExplicitUnknownAxesAndScopeAreNotDefaulted()
    {
        var phaseJson = MetadataNode();
        phaseJson["capturePhase"] = "future-capture-phase";
        Assert.ThrowsExactly<JsonException>(() => JsonSerializer.Deserialize<ClassMetadata>(phaseJson.ToJsonString()));

        var scopeJson = MetadataNode();
        scopeJson["captureScope"] = "future-scope";
        Assert.ThrowsExactly<JsonException>(() => JsonSerializer.Deserialize<ClassMetadata>(scopeJson.ToJsonString()));

        var modeJson = MetadataNode();
        modeJson.Remove("captureScope");
        modeJson["mode"] = "future-mode";
        Assert.ThrowsExactly<JsonException>(() => JsonSerializer.Deserialize<ClassMetadata>(modeJson.ToJsonString()));
    }

    private static JsonObject MetadataNode() =>
        JsonNode.Parse(JsonSerializer.Serialize(new ClassMetadata
        {
            Subject = "Prueba",
            Mode = CaptureMode.InPerson,
            CaptureScope = CaptureScope.Microphone,
            State = ProcessingState.Complete,
            SessionPhase = SessionPhase.Complete,
            CapturePhase = CapturePhase.Idle,
            AsrPhase = AsrPhase.Idle,
        }))!.AsObject();
}
