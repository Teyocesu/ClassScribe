using System.Text;
using System.Text.Json;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Encodings.Web;

namespace ClassScribe.Core;

public sealed record SessionSummary(
    string Folder,
    ClassMetadata Metadata,
    bool IsRecoverable,
    bool HasValidAudio,
    bool HasRecoverableRaw,
    string? PreferredTextPath,
    string? RecoveryReason);

public sealed class SessionStore
{
    private const long MaximumMetadataBytes = 1 * 1_024 * 1_024;
    private const long MaximumStructuredBytes = 64 * 1_024 * 1_024;
    private const long MaximumTextBytes = 64 * 1_024 * 1_024;
    private const long MaximumJournalBytes = 16 * 1_024 * 1_024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        WriteIndented = true,
    };

    public SessionStore(string? root = null)
    {
        Root = root ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ClassScribe",
            "Classes");
    }

    public string Root { get; }

    public string CreateFolder(string subject, DateTimeOffset? date = null)
    {
        var root = EnsureRootDirectory();
        var stamp = (date ?? DateTimeOffset.Now).ToLocalTime()
            .ToString("yyyy-MM-dd_HHmmss", CultureInfo.InvariantCulture);
        var slug = FilenameSlug.Create(subject);
        var baseName = $"{stamp}_{(slug.Length == 0 ? "clase" : slug)}";

        for (var attempt = 0; attempt < 128; attempt++)
        {
            // A random suffix prevents another local process from preparing a
            // predictable junction before ClassScribe reserves the directory.
            var nonce = RandomNumberGenerator.GetHexString(8).ToLowerInvariant();
            var folder = Path.Combine(root, $"{baseName}-{nonce}");
            if (Directory.Exists(folder))
            {
                continue;
            }

            try
            {
                Directory.CreateDirectory(folder);
                RejectDirectoryReparsePoint(folder);
                using var marker = new FileStream(
                    Path.Combine(folder, ".classscribe-session"),
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None);
                return folder;
            }
            catch (IOException) when (Directory.Exists(folder))
            {
                // A vanishingly unlikely collision or race: generate another suffix.
            }
        }

        throw new IOException("No se pudo reservar una carpeta única para la sesión.");
    }

    public async Task SaveMetadataAsync(
        ClassMetadata metadata,
        string folder,
        CancellationToken cancellationToken = default)
    {
        folder = EnsureSessionFolder(folder);
        await AtomicFile.WriteJsonAsync(
                Path.Combine(folder, "metadata.json"),
                metadata,
                JsonOptions,
                cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task SaveLiveAsync(
        string text,
        ClassMetadata metadata,
        string folder,
        string checkpoint,
        CancellationToken cancellationToken = default)
    {
        folder = EnsureSessionFolder(folder);
        var context = $"Materia: {metadata.Subject}\n"
            + $"Fecha: {metadata.StartedAt.ToLocalTime():D} {metadata.StartedAt.ToLocalTime():t}\n"
            + $"Duración: {Timecode.Display(metadata.Duration)}\n"
            + $"Modo: {metadata.Mode.ToSpanish()}\n"
            + $"Fuente: {metadata.Source}\n\n";
        await AtomicFile.WriteTextAsync(
            Path.Combine(folder, "live-transcript.txt"),
            context + text,
            cancellationToken).ConfigureAwait(false);
        await AtomicFile.WriteTextAsync(
            Path.Combine(folder, "live-transcript.md"),
            TranscriptExporter.Markdown(metadata.Subject, metadata.StartedAt, text),
            cancellationToken).ConfigureAwait(false);
        await AtomicFile.WriteJsonAsync(
            Path.Combine(folder, "live-transcript.json"),
            new { version = 1, checkpoint, text, updatedAt = DateTimeOffset.UtcNow },
            JsonOptions,
            cancellationToken).ConfigureAwait(false);

        var journalLine = JsonSerializer.Serialize(
            new { id = Guid.NewGuid(), checkpoint, text, updatedAt = DateTimeOffset.UtcNow },
            JsonOptions) + "\n";
        await AppendJournalAsync(
            Path.Combine(folder, "live-transcript-journal.jsonl"),
            journalLine,
            cancellationToken).ConfigureAwait(false);
    }

    public Task SaveFinalAsync(
        ClassMetadata metadata,
        IReadOnlyList<TranscriptSegment> all,
        IReadOnlyList<TranscriptSegment> professor,
        IReadOnlyList<ReviewItem> review,
        IReadOnlyList<SpeakerRecord> speakers,
        string folder,
        HumanCorrectionUpdate? humanCorrection = null,
        CancellationToken cancellationToken = default,
        DiarizationProposal? diarizationProposal = null) =>
        SaveProjectionAsync(
            metadata,
            all,
            professor,
            review,
            speakers,
            folder,
            automaticAllText: null,
            automaticProfessorText: null,
            humanCorrection: humanCorrection,
            cancellationToken: cancellationToken,
            diarizationProposal: diarizationProposal);

    public Task SaveAutomaticProjectionAsync(
        ClassMetadata metadata,
        IReadOnlyList<TranscriptSegment> all,
        IReadOnlyList<TranscriptSegment> professor,
        IReadOnlyList<ReviewItem> review,
        IReadOnlyList<SpeakerRecord> speakers,
        string folder,
        string automaticAllText,
        string automaticProfessorText,
        CancellationToken cancellationToken = default,
        DiarizationProposal? diarizationProposal = null) =>
        SaveProjectionAsync(
            metadata,
            all,
            professor,
            review,
            speakers,
            folder,
            automaticAllText,
            automaticProfessorText,
            humanCorrection: null,
            cancellationToken: cancellationToken,
            diarizationProposal: diarizationProposal);

    private async Task SaveProjectionAsync(
        ClassMetadata metadata,
        IReadOnlyList<TranscriptSegment> all,
        IReadOnlyList<TranscriptSegment> professor,
        IReadOnlyList<ReviewItem> review,
        IReadOnlyList<SpeakerRecord> speakers,
        string folder,
        string? automaticAllText,
        string? automaticProfessorText,
        HumanCorrectionUpdate? humanCorrection,
        CancellationToken cancellationToken,
        DiarizationProposal? diarizationProposal)
    {
        folder = EnsureSessionFolder(folder);
        var overlayPath = Path.Combine(folder, "human-correction-overlay.json");
        var overlay = await ReadJsonAsync<HumanCorrectionOverlay>(
                overlayPath)
            .ConfigureAwait(false);
        if (humanCorrection is not null)
        {
            var existingOverlay = overlay ?? new HumanCorrectionOverlay();
            overlay = existingOverlay with
            {
                Operations = existingOverlay.Operations
                    .Concat(humanCorrection.Operations.Where(operation =>
                        existingOverlay.Operations.All(existing => existing.Id != operation.Id)))
                    .ToArray(),
                EditedAllText = humanCorrection.AllText ?? existingOverlay.EditedAllText,
                EditedProfessorText = humanCorrection.ProfessorText ?? existingOverlay.EditedProfessorText,
            };
            await AtomicFile.WriteJsonAsync(
                    overlayPath,
                    overlay,
                    JsonOptions,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        if (overlay is not null)
        {
            metadata = metadata with
            {
                HumanCorrectionOverlayReference = metadata.HumanCorrectionOverlayReference
                    ?? new HumanCorrectionOverlayReference { RelativePath = "human-correction-overlay.json" },
            };
        }

        var proposalPath = Path.Combine(folder, "diarization-proposals.json");
        var proposalDocument = await ReadJsonAsync<DiarizationProposalDocument>(proposalPath)
            .ConfigureAwait(false)
            ?? new DiarizationProposalDocument();
        if (diarizationProposal is not null
            && proposalDocument.Proposals.All(existing => existing.ProposalID != diarizationProposal.ProposalID))
        {
            proposalDocument = proposalDocument with
            {
                Proposals = proposalDocument.Proposals.Append(diarizationProposal).ToArray(),
            };
        }
        if (diarizationProposal is not null
            && metadata.DiarizationProposalReferences.All(existing => existing.ProposalID != diarizationProposal.ProposalID))
        {
            metadata = metadata with
            {
                DiarizationProposalReferences = metadata.DiarizationProposalReferences
                    .Append(new DiarizationProposalReference
                    {
                        ProposalID = diarizationProposal.ProposalID,
                        RelativePath = "diarization-proposals.json",
                    })
                    .ToArray(),
            };
        }
        var proposalReferences = metadata.DiarizationProposalReferences.ToList();
        foreach (var proposal in proposalDocument.Proposals)
        {
            if (proposalReferences.All(existing => existing.ProposalID != proposal.ProposalID))
            {
                proposalReferences.Add(new DiarizationProposalReference
                {
                    ProposalID = proposal.ProposalID,
                    RelativePath = "diarization-proposals.json",
                });
            }
        }
        metadata = metadata with { DiarizationProposalReferences = proposalReferences };

        await AtomicFile.WriteJsonAsync(
                proposalPath,
                proposalDocument,
                JsonOptions,
                cancellationToken)
            .ConfigureAwait(false);
        await AtomicFile.WriteJsonAsync(
            Path.Combine(folder, "all-speakers.json"), all, JsonOptions, cancellationToken).ConfigureAwait(false);
        await AtomicFile.WriteJsonAsync(
            Path.Combine(folder, "review.json"), review, JsonOptions, cancellationToken).ConfigureAwait(false);
        await AtomicFile.WriteJsonAsync(
            Path.Combine(folder, "speakers.json"), speakers, JsonOptions, cancellationToken).ConfigureAwait(false);

        var allText = overlay?.EditedAllText ?? automaticAllText ?? TranscriptExporter.PlainText(all);
        var professorText = overlay?.EditedProfessorText ?? automaticProfessorText ?? TranscriptExporter.PlainText(professor);
        await SaveTextPairAsync("all-speakers", allText, metadata, folder, cancellationToken).ConfigureAwait(false);
        await SaveTextPairAsync("professor", professorText, metadata, folder, cancellationToken).ConfigureAwait(false);
        await AtomicFile.WriteTextAsync(
            Path.Combine(folder, "professor.srt"),
            TranscriptExporter.Srt(professor),
            cancellationToken).ConfigureAwait(false);

        // A complete metadata state is the commit marker and is written last.
        await SaveMetadataAsync(metadata, folder, cancellationToken).ConfigureAwait(false);
    }

    public async Task SaveEditedDocumentsAsync(
        ClassMetadata metadata,
        string folder,
        string allText,
        string professorText,
        CancellationToken cancellationToken = default)
    {
        folder = EnsureSessionFolder(folder);
        var overlay = await ReadJsonAsync<HumanCorrectionOverlay>(
                Path.Combine(folder, "human-correction-overlay.json"))
            .ConfigureAwait(false)
            ?? new HumanCorrectionOverlay();
        overlay = overlay with
        {
            EditedAllText = allText,
            EditedProfessorText = professorText,
        };
        await AtomicFile.WriteJsonAsync(
                Path.Combine(folder, "human-correction-overlay.json"),
                overlay,
                JsonOptions,
                cancellationToken)
            .ConfigureAwait(false);
        metadata = metadata with
        {
            HumanCorrectionOverlayReference = metadata.HumanCorrectionOverlayReference
                ?? new HumanCorrectionOverlayReference { RelativePath = "human-correction-overlay.json" },
        };
        await SaveTextPairAsync("all-speakers", allText, metadata, folder, cancellationToken)
            .ConfigureAwait(false);
        await SaveTextPairAsync("professor", professorText, metadata, folder, cancellationToken)
            .ConfigureAwait(false);
        await SaveMetadataAsync(metadata, folder, cancellationToken).ConfigureAwait(false);
    }

    public async Task<ASRTranscriptReference> SaveAsrOriginalAsync(
        ClassMetadata metadata,
        IReadOnlyList<TranscriptSegment> segments,
        string folder,
        CancellationToken cancellationToken = default)
    {
        folder = EnsureSessionFolder(folder);
        var runID = Guid.NewGuid();
        var relativePath = $"asr-original-{runID:N}.json";
        var reference = new ASRTranscriptReference
        {
            RunID = runID,
            RelativePath = relativePath,
            Language = NormalizeLanguage(metadata.Language),
            AttemptID = metadata.AttemptID,
        };
        var artifact = new ASRTranscriptArtifact
        {
            RunID = runID,
            CreatedAt = DateTimeOffset.UtcNow,
            Language = reference.Language,
            AttemptID = metadata.AttemptID,
            Segments = segments,
        };
        await AtomicFile.WriteJsonAsync(
                Path.Combine(folder, relativePath),
                artifact,
                JsonOptions,
                cancellationToken)
            .ConfigureAwait(false);
        return reference;
    }

    public async Task<string> RecoverRawAudioAsync(
        string folder,
        CancellationToken cancellationToken = default)
    {
        folder = EnsureSessionFolder(folder);
        var wavePath = Path.Combine(folder, "source.wav");
        try
        {
            PcmWaveFile.Validate(wavePath);
            return wavePath;
        }
        catch (Exception error) when (error is IOException
                                           or UnauthorizedAccessException
                                           or InvalidDataException)
        {
            // Rebuild from the durable PCM stream below.
        }

        var masterPath = Path.Combine(folder, "master.raw");
        var manifestPath = Path.Combine(folder, "audio-manifest.json");
        if (TryValidateMaster(masterPath, manifestPath, out _))
        {
            await PcmWaveFile.DeriveFromMasterAsync(
                    masterPath,
                    manifestPath,
                    wavePath,
                    cancellationToken)
                .ConfigureAwait(false);
            return wavePath;
        }

        var rawPath = Path.Combine(folder, "source.raw");
        await PcmWaveFile.WrapRawAsync(rawPath, wavePath, cancellationToken).ConfigureAwait(false);
        File.Delete(rawPath);
        return wavePath;
    }

    public IReadOnlyList<SessionSummary> ScanSessions()
    {
        if (!Directory.Exists(Root))
        {
            return [];
        }

        var summaries = new List<SessionSummary>();
        try
        {
            RejectDirectoryReparsePoint(Root);
            foreach (var folder in Directory.EnumerateDirectories(Root))
            {
                try
                {
                    RejectDirectoryReparsePoint(folder);
                    if (InspectSession(folder) is { } summary)
                    {
                        summaries.Add(summary);
                    }
                }
                catch (Exception error) when (error is IOException
                                                   or UnauthorizedAccessException
                                                   or InvalidDataException
                                                   or JsonException)
                {
                    // One damaged or inaccessible folder must not hide every
                    // other recoverable class from the history screen.
                }
            }
        }
        catch (Exception error) when (error is IOException
                                           or UnauthorizedAccessException
                                           or InvalidDataException)
        {
            return [];
        }

        return summaries.OrderByDescending(static summary => summary.Metadata.StartedAt).ToArray();
    }

    private static SessionSummary? InspectSession(string folder)
    {
        var metadataPath = Path.Combine(folder, "metadata.json");
        ClassMetadata? metadata = null;
        var metadataWasCorrupt = false;
        if (IsRegularFileWithinLimit(metadataPath, MaximumMetadataBytes))
        {
            var metadataText = File.ReadAllText(metadataPath);
            try
            {
                using var document = JsonDocument.Parse(metadataText);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    // Valid JSON with a non-object root is not a legacy
                    // metadata document and must not be inferred.
                    return null;
                }

                if (document.RootElement.TryGetProperty("schemaVersion", out var schemaVersion)
                    && schemaVersion.TryGetInt32(out var version)
                    && version > 2)
                {
                    // A future schema is unsupported, not legacy. Leave the
                    // session untouched instead of recovering it by guessing
                    // fields and later downgrading it to v2.
                    return null;
                }

                try
                {
                    // Syntax-valid metadata is authoritative. A supported
                    // schema with an explicit unknown token is invalid, not
                    // an invitation to apply legacy defaults.
                    metadata = JsonSerializer.Deserialize<ClassMetadata>(metadataText, JsonOptions);
                }
                catch (JsonException)
                {
                    return null;
                }
            }
            catch (JsonException)
            {
                // v0.7 could leave metadata partially written. Keep the
                // artifacts recoverable, but never rewrite this file merely
                // because history was scanned.
                metadataWasCorrupt = true;
            }
        }

        var audioPath = Path.Combine(folder, "source.wav");
        var rawPath = Path.Combine(folder, "source.raw");
        var masterPath = Path.Combine(folder, "master.raw");
        var manifestPath = Path.Combine(folder, "audio-manifest.json");
        var audioValid = TryValidateWave(audioPath, out var duration);
        var rawValid = TryValidateRaw(rawPath);
        var masterValid = TryValidateMaster(masterPath, manifestPath, out var masterDuration);
        if (!audioValid && masterValid)
        {
            duration = masterDuration;
        }
        var preferredText = PreferredTextPath(folder);
        if (metadata is null && !audioValid && !rawValid && !masterValid && preferredText is null)
        {
            return null;
        }

        metadata ??= InferMetadata(folder, duration);
        metadata = metadata with
        {
            FolderPath = Path.GetFullPath(folder),
            Duration = Math.Max(metadata.Duration, duration),
        };
        var hasFinal = File.Exists(Path.Combine(folder, "all-speakers.json"))
            && !string.IsNullOrWhiteSpace(ReadText(Path.Combine(folder, "all-speakers.txt")));
        var recoverable = metadataWasCorrupt
            || metadata.State != ProcessingState.Complete
            || !audioValid
            || !hasFinal;
        var reason = metadataWasCorrupt
            ? "La metadata quedó truncada o corrupta; el audio y el texto disponibles se conservaron."
            : !audioValid && masterValid
            ? "El WAV derivado falta o está incompleto, pero el master fiel puede reconstruirse."
            : !audioValid && rawValid
            ? "El WAV quedó incompleto, pero el audio crudo puede reconstruirse."
            : !audioValid
                ? "Falta un WAV válido; el texto guardado sigue disponible."
                : !hasFinal
                    ? "La grabación no terminó de procesarse."
                    : metadata.State != ProcessingState.Complete
                        ? "La sesión quedó interrumpida antes de confirmar su estado final."
                        : null;
        return new SessionSummary(
            folder,
            metadata,
            recoverable,
            audioValid,
            masterValid || rawValid,
            preferredText,
            reason);
    }

    private static ClassMetadata InferMetadata(string folder, double duration)
    {
        var name = Path.GetFileName(folder);
        var startedAt = Directory.GetCreationTime(folder);
        if (name.Length >= 17
            && DateTime.TryParseExact(
                name[..17],
                "yyyy-MM-dd_HHmmss",
                null,
                System.Globalization.DateTimeStyles.AssumeLocal,
                out var parsed))
        {
            startedAt = parsed;
        }

        var subjectSlug = name.Length > 18 ? name[18..] : string.Empty;
        var nonceSeparator = subjectSlug.LastIndexOf('-');
        if (nonceSeparator >= 0
            && subjectSlug.Length - nonceSeparator - 1 == 8
            && subjectSlug[(nonceSeparator + 1)..].All(Uri.IsHexDigit))
        {
            subjectSlug = subjectSlug[..nonceSeparator];
        }

        var subject = subjectSlug.Length > 0 ? subjectSlug.Replace('-', ' ') : "Clase recuperada";
        return new ClassMetadata
        {
            Subject = subject,
            StartedAt = startedAt,
            Duration = duration,
            Mode = CaptureMode.InPerson,
            Source = "Fuente recuperada",
            State = ProcessingState.Recoverable,
            FolderPath = Path.GetFullPath(folder),
            SchemaVersion = 1,
            SessionPhase = ClassScribe.Core.SessionPhase.Recoverable,
            CapturePhase = ClassScribe.Core.CapturePhase.FailedRecoverable,
            AsrPhase = ClassScribe.Core.AsrPhase.FailedRecoverable,
        };
    }

    private static async Task SaveTextPairAsync(
        string basename,
        string text,
        ClassMetadata metadata,
        string folder,
        CancellationToken cancellationToken)
    {
        await AtomicFile.WriteTextAsync(
            Path.Combine(folder, $"{basename}.txt"), text, cancellationToken).ConfigureAwait(false);
        await AtomicFile.WriteTextAsync(
            Path.Combine(folder, $"{basename}.md"),
            TranscriptExporter.Markdown(metadata.Subject, metadata.StartedAt, text),
            cancellationToken).ConfigureAwait(false);
    }

    private string EnsureSessionFolder(string folder)
    {
        var fullRoot = EnsureRootDirectory();
        var fullFolder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (!string.Equals(Path.GetDirectoryName(fullFolder), fullRoot, comparison))
        {
            throw new UnauthorizedAccessException("La sesión debe permanecer dentro de la carpeta de ClassScribe.");
        }

        RejectDirectoryReparsePoint(fullFolder);
        return fullFolder;
    }

    private static string? PreferredTextPath(string folder)
    {
        foreach (var name in new[]
                 {
                     "professor.txt", "all-speakers.txt", "live-transcript-edit.txt",
                     "live-transcript.txt", "recovered-transcript.txt",
                 })
        {
            var path = Path.Combine(folder, name);
            if (!string.IsNullOrWhiteSpace(ReadText(path)))
            {
                return path;
            }
        }

        return null;
    }

    private static string? ReadText(string path)
    {
        try
        {
            return IsRegularFileWithinLimit(path, MaximumTextBytes) ? File.ReadAllText(path) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static async Task<T?> ReadJsonAsync<T>(string path)
    {
        try
        {
            if (!IsRegularFileWithinLimit(path, MaximumStructuredBytes))
            {
                return default;
            }

            await using var stream = File.OpenRead(path);
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return default;
        }
    }

    private static string NormalizeLanguage(string? language) => language?.Trim().ToLowerInvariant() switch
    {
        "en" => "en",
        "fr" => "fr",
        _ => "es",
    };

    private static bool TryValidateWave(string path, out double duration)
    {
        try
        {
            duration = PcmWaveFile.Validate(path);
            return true;
        }
        catch (Exception error) when (error is IOException
                                           or UnauthorizedAccessException
                                           or InvalidDataException)
        {
            duration = 0;
            return false;
        }
    }

    private static bool TryValidateRaw(string path)
    {
        try
        {
            PcmWaveFile.ValidateRaw(path);
            return true;
        }
        catch (Exception error) when (error is IOException
                                           or UnauthorizedAccessException
                                           or InvalidDataException)
        {
            return false;
        }
    }

    private static bool TryValidateMaster(string masterPath, string manifestPath, out double duration)
    {
        try
        {
            duration = PcmWaveFile.ValidateMaster(masterPath, manifestPath);
            return true;
        }
        catch (Exception error) when (error is IOException
                                           or UnauthorizedAccessException
                                           or InvalidDataException
                                           or JsonException)
        {
            duration = 0;
            return false;
        }
    }

    private static async Task AppendJournalAsync(
        string path,
        string line,
        CancellationToken cancellationToken)
    {
        RejectFileReparsePointIfPresent(path);
        var bytes = Encoding.UTF8.GetBytes(line);
        if (File.Exists(path) && new FileInfo(path).Length + bytes.Length > MaximumJournalBytes)
        {
            // The current atomic snapshot remains authoritative. Retain one
            // fresh journal entry instead of growing quadratically for long classes.
            await AtomicFile.WriteTextAsync(path, line, cancellationToken).ConfigureAwait(false);
            return;
        }

        await using var stream = new FileStream(
            path,
            FileMode.Append,
            FileAccess.Write,
            FileShare.Read,
            4_096,
            FileOptions.Asynchronous | FileOptions.WriteThrough);
        await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        stream.Flush(flushToDisk: true);
    }

    private string EnsureRootDirectory()
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Root));
        Directory.CreateDirectory(root);
        RejectDirectoryReparsePoint(root);
        return root;
    }

    private static bool IsRegularFileWithinLimit(string path, long maximumBytes)
    {
        try
        {
            if (!File.Exists(path))
            {
                return false;
            }

            var attributes = File.GetAttributes(path);
            var length = new FileInfo(path).Length;
            return (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0
                && length >= 0
                && length <= maximumBytes;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void RejectDirectoryReparsePoint(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0
            || (attributes & FileAttributes.Directory) == 0)
        {
            throw new UnauthorizedAccessException("Las carpetas de sesión no pueden ser enlaces ni puntos de unión.");
        }
    }

    private static void RejectFileReparsePointIfPresent(string path)
    {
        if (File.Exists(path)
            && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException("Los archivos de sesión no pueden ser enlaces ni puntos de unión.");
        }
    }
}

internal static class AtomicFile
{
    public static Task WriteJsonAsync<T>(
        string path,
        T value,
        JsonSerializerOptions options,
        CancellationToken cancellationToken) =>
        WriteAsync(path, stream => JsonSerializer.SerializeAsync(stream, value, options, cancellationToken), cancellationToken);

    public static Task WriteTextAsync(string path, string text, CancellationToken cancellationToken) =>
        WriteAsync(
            path,
            async stream =>
            {
                var bytes = Encoding.UTF8.GetBytes(text);
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            },
            cancellationToken);

    private static async Task WriteAsync(
        string path,
        Func<FileStream, Task> writer,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("El archivo necesita una carpeta de destino.");
        Directory.CreateDirectory(directory);
        var directoryAttributes = File.GetAttributes(directory);
        if ((directoryAttributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException("La carpeta de destino no puede ser un enlace o punto de unión.");
        }

        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new UnauthorizedAccessException("El archivo de destino no puede ser un enlace o punto de unión.");
        }

        var temporary = Path.Combine(directory, $".classscribe-write-{Guid.NewGuid():N}.tmp");

        try
        {
            await using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                16 * 1_024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await writer(stream).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }
}
