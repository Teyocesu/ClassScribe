using System.Windows;
using System.Windows.Threading;

namespace ClassScribe.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        var localization = AppLocalization.Instance;
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
                localization["Windows11Required"],
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
            AppLocalization.Instance.Get("UnexpectedError", e.Exception.Message),
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
