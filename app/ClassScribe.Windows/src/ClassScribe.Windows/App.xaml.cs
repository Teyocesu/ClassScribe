using System.Windows;
using System.Windows.Threading;

namespace ClassScribe.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += HandleDispatcherException;
        AppDomain.CurrentDomain.UnhandledException += HandleUnhandledException;
        TaskScheduler.UnobservedTaskException += HandleUnobservedException;
        base.OnStartup(e);

        if (DiarizationWorker.IsWorkerInvocation(e.Args))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Shutdown(DiarizationWorker.RunWorker(e.Args));
            return;
        }

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            MessageBox.Show(
                "ClassScribe para Windows requiere Windows 11 o una versión posterior.",
                "ClassScribe",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(2);
            return;
        }

        var window = new MainWindow();
        MainWindow = window;
        window.Show();
    }

    private static void HandleDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        CrashLog.Write(e.Exception);
        MessageBox.Show(
            $"ClassScribe encontró un error inesperado. La grabación recuperable se conserva.\n\n{e.Exception.Message}",
            "ClassScribe",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
    }

    private static void HandleUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception exception)
        {
            CrashLog.Write(exception);
        }
    }

    private static void HandleUnobservedException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        CrashLog.Write(e.Exception);
        e.SetObserved();
    }
}
