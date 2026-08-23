using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Windows;
using ClassScribe.Core;
using Microsoft.Win32;

namespace ClassScribe.Windows;

public partial class MainWindow : Window, IAsyncDisposable
{
    private readonly MainViewModel viewModel = new();
    private bool initialized;
    private bool closeReady;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = viewModel;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await viewModel.InitializeAsync().ConfigureAwait(true);
            initialized = true;
        }
        catch (Exception error)
        {
            viewModel.ReportUiError(error);
        }
    }

    private async void CaptureMode_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (initialized)
        {
            await RunUiActionAsync(viewModel.RefreshSourcesAsync).ConfigureAwait(true);
        }
    }

    private async void RefreshSources_Click(object sender, RoutedEventArgs e) =>
        await RunUiActionAsync(viewModel.RefreshSourcesAsync).ConfigureAwait(true);

    private async void Start_Click(object sender, RoutedEventArgs e) =>
        await RunUiActionAsync(viewModel.StartAsync).ConfigureAwait(true);

    private async void Stop_Click(object sender, RoutedEventArgs e) =>
        await RunUiActionAsync(viewModel.StopAsync).ConfigureAwait(true);

    private void Pause_Click(object sender, RoutedEventArgs e) => viewModel.TogglePause();

    private void Cancel_Click(object sender, RoutedEventArgs e) => viewModel.CancelCurrentOperation();

    private async void Reprocess_Click(object sender, RoutedEventArgs e) =>
        await RunUiActionAsync(viewModel.ReprocessCurrentAsync).ConfigureAwait(true);

    private async void LoadHistory_Click(object sender, RoutedEventArgs e) =>
        await RunUiActionAsync(viewModel.LoadSelectedHistoryAsync).ConfigureAwait(true);

    private async void ApplyProfessor_Click(object sender, RoutedEventArgs e) =>
        await RunUiActionAsync(viewModel.ApplyProfessorSelectionAsync).ConfigureAwait(true);

    private async void Save_Click(object sender, RoutedEventArgs e) =>
        await RunUiActionAsync(viewModel.SaveEditsAsync).ConfigureAwait(true);

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(viewModel.ChatEnvelope());
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException
                                           or ArgumentException)
        {
            viewModel.ReportUiError(error);
        }
    }

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var slug = FilenameSlug.Create(viewModel.Subject);
            var dialog = new SaveFileDialog
            {
                Title = "Exportar transcripción",
                FileName = $"{(slug.Length == 0 ? "clase" : slug)}-transcripcion.txt",
                DefaultExt = ".txt",
                AddExtension = true,
                OverwritePrompt = true,
                Filter = "Texto (*.txt)|*.txt|Markdown (*.md)|*.md",
            };
            if (dialog.ShowDialog(this) != true)
            {
                return;
            }

            var bestText = TranscriptActions.BestAvailable(
                viewModel.ProfessorText,
                viewModel.AllText,
                viewModel.LiveText);
            var exported = dialog.FilterIndex == 2
                ? TranscriptExporter.Markdown(viewModel.Subject, viewModel.CurrentStartedAt, bestText)
                : bestText;
            await File.WriteAllTextAsync(
                    dialog.FileName,
                    exported,
                    new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
                .ConfigureAwait(true);
        }
        catch (Exception error) when (error is IOException
                                           or UnauthorizedAccessException
                                           or ArgumentException)
        {
            viewModel.ReportUiError(error);
        }
    }

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (viewModel.CurrentFolder is not { } folder)
            {
                return;
            }

            var startInfo = new ProcessStartInfo("explorer.exe")
            {
                UseShellExecute = false,
            };
            startInfo.ArgumentList.Add(folder);
            _ = Process.Start(startInfo);
        }
        catch (Exception error) when (error is InvalidOperationException
                                           or System.ComponentModel.Win32Exception)
        {
            viewModel.ReportUiError(error);
        }
    }

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (closeReady)
        {
            return;
        }

        e.Cancel = true;
        if (viewModel.IsRecording)
        {
            var answer = MessageBox.Show(
                this,
                "Hay una grabación activa. ¿Quieres detenerla, guardar el audio y salir?",
                "ClassScribe",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (answer != MessageBoxResult.Yes)
            {
                return;
            }

            await viewModel.StopForExitAsync().ConfigureAwait(true);
        }
        else if (viewModel.IsBusy)
        {
            var answer = MessageBox.Show(
                this,
                "Hay un procesamiento en curso. ¿Quieres cancelarlo de forma segura y salir?",
                "ClassScribe",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (answer != MessageBoxResult.Yes)
            {
                return;
            }

            viewModel.CancelCurrentOperation();
        }

        await DisposeAsync().ConfigureAwait(true);
        closeReady = true;
        Close();
    }

    public async ValueTask DisposeAsync()
    {
        await viewModel.DisposeAsync().ConfigureAwait(true);
        GC.SuppressFinalize(this);
    }

    private async Task RunUiActionAsync(Func<Task> action)
    {
        try
        {
            await action().ConfigureAwait(true);
        }
        catch (Exception error)
        {
            CrashLog.Write(error);
            viewModel.ReportUiError(error);
        }
    }
}
