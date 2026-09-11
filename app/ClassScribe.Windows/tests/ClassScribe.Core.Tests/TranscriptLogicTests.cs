using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class TranscriptLogicTests
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    [TestMethod]
    public void OverlapDeduplicatorRemovesOnlyMatchingPrefix()
    {
        var merged = OverlapDeduplicator.Merge(
            "La derivada mide el cambio instantáneo.",
            "cambio instantáneo. Ahora veremos un ejemplo");

        Assert.AreEqual(
            "La derivada mide el cambio instantáneo. Ahora veremos un ejemplo",
            merged);
    }

    [TestMethod]
    public void TimecodeClampsInvalidValues()
    {
        Assert.AreEqual("00:00", Timecode.Display(double.NaN));
        Assert.AreEqual("00:00:00,000", Timecode.Srt(double.NegativeInfinity));
        Assert.AreEqual("1:01:01", Timecode.Display(3_661.9));
    }

    [TestMethod]
    public void FilenameSlugIsWindowsSafeAndUtf8Bounded()
    {
        Assert.AreEqual("clase-con", FilenameSlug.Create("CON"));
        Assert.AreEqual("álgebra-lineal", FilenameSlug.Create("  Álgebra / Lineal  "));
        var slug = FilenameSlug.Create(string.Concat(Enumerable.Repeat("á", 200)));
        Assert.IsLessThanOrEqualTo(120, Encoding.UTF8.GetByteCount(slug));
    }

    [TestMethod]
    public void FullTranscriptPrefersAllTextAndFallsBackToLiveText()
    {
        Assert.AreEqual(
            "transcripción completa",
            TranscriptActions.FullTranscript("transcripción completa", "texto live"));
        Assert.AreEqual(
            "texto live",
            TranscriptActions.FullTranscript("  ", "texto live"));
    }

    [TestMethod]
    public void SpeakerAssignmentMarksOverlapForReview()
    {
        var transcript = new[]
        {
            new TranscriptSegment { Start = 0, End = 4, Text = "Ejemplo", SpeakerID = "Persona desconocida" },
        };
        var diarization = new[]
        {
            new DiarizationSpan { Start = 0, End = 3, SpeakerID = "Persona 1", Quality = 0.9 },
            new DiarizationSpan { Start = 2, End = 4, SpeakerID = "Persona 2", Quality = 0.8 },
        };

        var result = SpeakerAssignment.Assign(transcript, diarization);

        Assert.AreEqual("Persona 1", result.Segments[0].SpeakerID);
        Assert.IsTrue(result.Segments[0].OverlappingVoices);
        Assert.HasCount(1, result.Review);
    }

    [TestMethod]
    public void SilenceIsRejectedBeforeAsrTextCanBeAccepted()
    {
        var evidence = SpeechPresenceEvidence.None;

        Assert.IsFalse(evidence.HasSpeech);
        Assert.IsNull(AsrResultAcceptancePolicy.Accept("hipótesis", evidence));
        Assert.IsEmpty(SpeechPresenceAcceptancePolicy.FilterSegments(
            [new TranscriptSegment { Start = 0, End = 1, Text = "hipótesis" }],
            evidence));
    }

    [TestMethod]
    public void SpeechOverlapKeepsOriginalAsrSegmentAtThePaddedBoundary()
    {
        var evidence = new SpeechPresenceEvidence(
            [new SpeechPresenceRegion(1, 2)]);

        Assert.IsTrue(SpeechPresenceAcceptancePolicy.Intersects(
            1.2,
            1.4,
            evidence.Regions));
        Assert.IsTrue(SpeechPresenceAcceptancePolicy.Intersects(
            0.7,
            0.8,
            evidence.Regions));
        Assert.IsTrue(SpeechPresenceAcceptancePolicy.Intersects(
            2.3,
            2.4,
            evidence.Regions));
    }

    [TestMethod]
    public void SpeechFilterRejectsSegmentOutsideThePaddedRegions()
    {
        var evidence = new SpeechPresenceEvidence(
            [new SpeechPresenceRegion(1, 2)]);
        var segment = new TranscriptSegment { Start = 2.31, End = 2.6, Text = "ruido" };

        Assert.IsFalse(SpeechPresenceAcceptancePolicy.Intersects(
            segment.Start,
            segment.End,
            evidence.Regions));
        Assert.IsEmpty(SpeechPresenceAcceptancePolicy.FilterSegments([segment], evidence));
    }

    [TestMethod]
    public void VadFailurePreservesOriginalAsrSegments()
    {
        var original = new[]
        {
            new TranscriptSegment { Start = 4, End = 5, Text = "texto ASR" },
        };

        CollectionAssert.AreEqual(
            original,
            SpeechPresenceAcceptancePolicy.FilterSegments(original, evidence: null));
    }

    [TestMethod]
    public void LiveRetryPolicyEventuallyDisablesAsrForTheSession()
    {
        var policy = new LiveTranscriptionRetryPolicy();
        var now = DateTimeOffset.UnixEpoch;
        var delays = new[]
        {
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(4),
            TimeSpan.FromSeconds(8),
            TimeSpan.FromSeconds(15),
            TimeSpan.FromSeconds(30),
        };

        foreach (var expected in delays)
        {
            Assert.AreEqual(expected, policy.RecordFailure(now));
            now += expected;
            Assert.IsTrue(policy.CanAttempt(now));
        }

        Assert.AreEqual(TimeSpan.Zero, policy.RecordFailure(now));
        Assert.IsTrue(policy.IsUnavailableForSession);
        Assert.IsFalse(policy.CanAttempt(now));
        policy.RecordSuccess();
        Assert.IsFalse(policy.IsUnavailableForSession);
        Assert.IsTrue(policy.CanAttempt(now));
    }

    [TestMethod]
    public void MetadataEmitsStableTokensAndReadsLegacySpanishAliases()
    {
        var metadata = new ClassMetadata
        {
            Subject = "Física",
            Mode = CaptureMode.Online,
            State = ProcessingState.Complete,
            Language = "fr",
        };

        var json = JsonSerializer.Serialize(metadata, JsonOptions);
        using var document = JsonDocument.Parse(json);
        Assert.AreEqual("online", document.RootElement.GetProperty("mode").GetString());
        Assert.AreEqual("complete", document.RootElement.GetProperty("state").GetString());

        var decoded = JsonSerializer.Deserialize<ClassMetadata>(
            "{\"mode\":\"Clase online\",\"state\":\"Transcripción final lista\",\"language\":\"fr\"}",
            JsonOptions);
        Assert.IsNotNull(decoded);
        Assert.AreEqual(CaptureMode.Online, decoded.Mode);
        Assert.AreEqual(ProcessingState.Complete, decoded.State);
        Assert.AreEqual("fr", decoded.Language);
    }
}
