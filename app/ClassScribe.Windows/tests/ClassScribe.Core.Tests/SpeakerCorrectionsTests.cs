using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class SpeakerCorrectionsTests
{
    private const string SpeakerA = "Persona 1";
    private const string SpeakerB = "Persona 2";
    private static readonly string[] HolaMundo = ["Hola", "mundo"];
    private static readonly string[] PersonaTres = ["Persona 3", "Persona 3", "Persona 3"];

    private static SpeakerRecord Speaker(string id, string? name = null, float[]? embedding = null) => new()
    {
        Id = id,
        DisplayName = name ?? id,
        Confidence = 0.9,
        Embedding = embedding,
    };

    private static TranscriptSegment Segment(
        string text,
        string speakerID,
        double start,
        double end,
        Guid? id = null,
        IReadOnlyList<TranscriptWordTiming>? timings = null) => new()
    {
        Id = id ?? Guid.NewGuid(),
        Text = text,
        SpeakerID = speakerID,
        Start = start,
        End = end,
        Confidence = 0.9,
        WordTimings = timings,
    };

    private static SpeakerCorrectionOperation Operation(
        SpeakerCorrectionKind kind,
        string? speakerID = null,
        string? targetSpeakerID = null,
        IReadOnlyList<Guid>? segmentIDs = null,
        double? anchorStart = null,
        double? anchorEnd = null,
        string? anchorText = null,
        int? splitAfter = null) => new()
    {
        Id = Guid.NewGuid(),
        Kind = kind,
        SpeakerID = speakerID,
        TargetSpeakerID = targetSpeakerID,
        SegmentIDs = segmentIDs ?? [],
        AnchorStart = anchorStart,
        AnchorEnd = anchorEnd,
        AnchorText = anchorText,
        SplitAfterWordIndex = splitAfter,
        CreatedAt = DateTimeOffset.UtcNow,
    };

    [TestMethod]
    public void RenameAndMergePreserveIdentityTextTimingAndEmbedding()
    {
        var first = Segment("Hola", SpeakerA, 0, 2);
        var second = Segment("mundo", SpeakerB, 2, 4);
        var rename = Operation(SpeakerCorrectionKind.Rename, SpeakerA) with { DisplayName = "Juan" };
        var merge = Operation(SpeakerCorrectionKind.Merge, SpeakerB, SpeakerA);
        var result = SpeakerCorrectionProjection.Apply(
            [first, second],
            [Speaker(SpeakerA, embedding: [1, 0]), Speaker(SpeakerB, embedding: [0, 1])],
            [],
            null,
            true,
            new HumanCorrectionOverlay { Operations = [rename, merge] });

        Assert.AreEqual(0, result.UnresolvedOperationIDs.Count);
        CollectionAssert.AreEqual(new[] { first.Id, second.Id }, result.Segments.Select(s => s.Id).ToArray());
        CollectionAssert.AreEqual(HolaMundo, result.Segments.Select(s => s.Text).ToArray());
        CollectionAssert.AreEqual(new[] { SpeakerA, SpeakerA }, result.Segments.Select(s => s.SpeakerID).ToArray());
        Assert.AreEqual("Juan", result.Speakers.Single().DisplayName);
        CollectionAssert.AreEqual(new float[] { 1, 0 }, result.Speakers.Single().Embedding);
        Assert.AreEqual(4, result.Speakers.Single().TotalSpeakingTime);
    }

    [TestMethod]
    public void MergeRejectsCyclesAndReassignsOnlySelectedSegment()
    {
        var first = Segment("uno", SpeakerA, 0, 1);
        var second = Segment("dos", SpeakerB, 1, 2);
        var merge = Operation(SpeakerCorrectionKind.Merge, SpeakerB, SpeakerA);
        Assert.IsFalse(SpeakerCorrectionProjection.CanMerge(
            SpeakerA,
            SpeakerB,
            [merge],
            new HashSet<string>([SpeakerA, SpeakerB], StringComparer.Ordinal)));

        var reassign = Operation(
            SpeakerCorrectionKind.Reassign,
            SpeakerB,
            SpeakerA,
            [second.Id],
            second.Start,
            second.End,
            second.Text);
        var result = SpeakerCorrectionProjection.Apply(
            [first, second],
            [Speaker(SpeakerA), Speaker(SpeakerB)],
            [],
            null,
            true,
            new HumanCorrectionOverlay { Operations = [reassign] });

        CollectionAssert.AreEqual(
            new[] { SpeakerA, SpeakerA },
            result.Segments.Select(s => s.SpeakerID).ToArray());
        Assert.AreEqual(first.Id, result.Segments[0].Id);
        Assert.AreEqual(second.Id, result.Segments[1].Id);
    }

    [TestMethod]
    public void MergeChainsRemainIdempotentAfterIntermediateSpeakerDisappears()
    {
        var first = Segment("uno", SpeakerA, 0, 1);
        var second = Segment("dos", SpeakerB, 1, 2);
        var third = Segment("tres", "Persona 3", 2, 3);
        var firstMerge = Operation(SpeakerCorrectionKind.Merge, SpeakerA, SpeakerB);
        var secondMerge = Operation(SpeakerCorrectionKind.Merge, SpeakerB, "Persona 3");
        var overlay = new HumanCorrectionOverlay { Operations = [firstMerge, secondMerge] };
        var initial = SpeakerCorrectionProjection.Apply(
            [first, second, third],
            [Speaker(SpeakerA), Speaker(SpeakerB), Speaker("Persona 3")],
            [],
            null,
            true,
            overlay);
        var reopened = SpeakerCorrectionProjection.Apply(
            initial.Segments,
            initial.Speakers,
            initial.Review,
            initial.ProfessorSpeakerID,
            initial.ProfessorSelectionIsAutomatic,
            overlay);

        Assert.AreEqual(0, initial.UnresolvedOperationIDs.Count);
        Assert.AreEqual(0, reopened.UnresolvedOperationIDs.Count);
        CollectionAssert.AreEqual(
            PersonaTres,
            reopened.Segments.Select(segment => segment.SpeakerID).ToArray());
    }

    [TestMethod]
    public void ManualProfessorSurvivesRenameAndMerge()
    {
        var segment = Segment("explicación", SpeakerB, 0, 1);
        var professor = Operation(SpeakerCorrectionKind.ProfessorConfirmation, SpeakerB);
        var merge = Operation(SpeakerCorrectionKind.Merge, SpeakerB, SpeakerA);
        var rename = Operation(SpeakerCorrectionKind.Rename, SpeakerA) with { DisplayName = "Profesora García" };
        var result = SpeakerCorrectionProjection.Apply(
            [segment],
            [Speaker(SpeakerA), Speaker(SpeakerB)],
            [],
            SpeakerB,
            false,
            new HumanCorrectionOverlay { Operations = [professor, merge, rename] });

        Assert.AreEqual(SpeakerA, result.ProfessorSpeakerID);
        Assert.IsFalse(result.ProfessorSelectionIsAutomatic);
        Assert.AreEqual("Profesora García", result.Speakers.Single().DisplayName);
    }

    [TestMethod]
    public void ManualSplitPreservesWordsAndRealTiming()
    {
        var timings = new TranscriptWordTiming[]
        {
            new() { Text = "Hola", Start = 10, End = 10.5 },
            new() { Text = "cómo", Start = 10.6, End = 11 },
            new() { Text = "estás", Start = 11.1, End = 11.7 },
            new() { Text = "bien", Start = 12, End = 12.4 },
            new() { Text = "gracias", Start = 12.5, End = 13 },
        };
        var source = Segment("Hola cómo estás bien gracias", SpeakerA, 10, 13, timings: timings);
        var operation = Operation(
            SpeakerCorrectionKind.Split,
            SpeakerA,
            segmentIDs: [source.Id],
            anchorStart: source.Start,
            anchorEnd: source.End,
            anchorText: source.Text,
            splitAfter: 3);
        var result = SpeakerCorrectionProjection.Apply(
            [source],
            [Speaker(SpeakerA)],
            [],
            null,
            true,
            new HumanCorrectionOverlay { Operations = [operation] });

        Assert.AreEqual(0, result.UnresolvedOperationIDs.Count);
        Assert.AreEqual(2, result.Segments.Count);
        Assert.AreEqual(source.Text, string.Join(' ', result.Segments.Select(s => s.Text)));
        Assert.AreEqual(10, result.Segments[0].Start);
        Assert.AreEqual(11.7, result.Segments[0].End);
        Assert.AreEqual(12, result.Segments[1].Start);
        Assert.AreEqual(13, result.Segments[1].End);
        CollectionAssert.AreEqual(
            timings.Select(t => t.Text).ToArray(),
            result.Segments.SelectMany(s => s.WordTimings!).Select(t => t.Text).ToArray());
    }

    [TestMethod]
    public void ReprocessingUsesAnchorsAndRejectsAmbiguity()
    {
        var oldID = Guid.NewGuid();
        var operation = Operation(
            SpeakerCorrectionKind.Reassign,
            SpeakerA,
            SpeakerB,
            [oldID],
            2,
            3,
            "repetido");
        var result = SpeakerCorrectionProjection.Apply(
            [Segment("repetido", SpeakerA, 2, 3)],
            [Speaker(SpeakerA), Speaker(SpeakerB)],
            [],
            null,
            true,
            new HumanCorrectionOverlay { Operations = [operation] });
        Assert.AreEqual(0, result.UnresolvedOperationIDs.Count);
        Assert.AreEqual(SpeakerB, result.Segments.Single().SpeakerID);

        var ambiguousOperation = operation with
        {
            AnchorStart = null,
            AnchorEnd = null,
        };
        var ambiguous = SpeakerCorrectionProjection.Apply(
            [Segment("repetido", SpeakerA, 2, 3), Segment("repetido", SpeakerA, 5, 6)],
            [Speaker(SpeakerA), Speaker(SpeakerB)],
            [],
            null,
            true,
            new HumanCorrectionOverlay { Operations = [ambiguousOperation] });
        CollectionAssert.Contains(ambiguous.UnresolvedOperationIDs.ToArray(), ambiguousOperation.Id);
        Assert.IsTrue(ambiguous.Segments.All(s => s.SpeakerID == SpeakerA));
    }

    [TestMethod]
    public void NamedPlainTextExportKeepsCompleteTranscript()
    {
        var segments = new[] { Segment("Texto completo", SpeakerA, 0, 1) };
        var text = TranscriptExporter.PlainText(segments, [Speaker(SpeakerA, "Juan")]);
        StringAssert.Contains(text, "Juan");
        StringAssert.Contains(text, "Texto completo");
    }
}
