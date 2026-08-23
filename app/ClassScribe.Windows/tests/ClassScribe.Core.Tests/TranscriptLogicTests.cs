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
    public void MetadataUsesTheMacCompatibleSpanishEnumValues()
    {
        var metadata = new ClassMetadata
        {
            Subject = "Física",
            Mode = CaptureMode.Online,
            State = ProcessingState.Complete,
            Language = "fr",
        };

        var json = JsonSerializer.Serialize(metadata, JsonOptions);
        StringAssert.Contains(json, "Clase online");
        StringAssert.Contains(json, "Transcripción final lista");

        var decoded = JsonSerializer.Deserialize<ClassMetadata>(json, JsonOptions);
        Assert.IsNotNull(decoded);
        Assert.AreEqual(CaptureMode.Online, decoded.Mode);
        Assert.AreEqual(ProcessingState.Complete, decoded.State);
        Assert.AreEqual("fr", decoded.Language);
    }
}
