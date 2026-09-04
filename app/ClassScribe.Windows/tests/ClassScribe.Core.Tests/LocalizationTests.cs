using System.Globalization;
using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class LocalizationTests
{
    [TestMethod]
    public void ExportMetadataUsesLocalizedLabelsWithoutChangingTranscript()
    {
        const string transcript = "Persona 1: El número π permanece igual.";
        var labels = new TranscriptMetadataLabels(
            "Subject",
            "Date",
            "Duration",
            "Mode",
            "Source",
            "Transcript",
            "Online class",
            "In-person class");

        var exported = TranscriptActions.ChatEnvelope(
            "Física",
            DateTimeOffset.UnixEpoch,
            12,
            CaptureMode.Online,
            "Zoom",
            transcript,
            labels,
            CultureInfo.GetCultureInfo("en-US"));

        StringAssert.Contains(exported, "Subject:");
        StringAssert.Contains(exported, "Date:");
        StringAssert.Contains(exported, "Duration:");
        StringAssert.Contains(exported, "Mode: Online class");
        StringAssert.Contains(exported, "Source:");
        StringAssert.Contains(exported, "Transcript:");
        StringAssert.Contains(exported, transcript);
        Assert.DoesNotContain("Materia:", exported);
    }
}
