using Microsoft.UI.Xaml;

namespace Scrap;

public partial class App : Application
{
    private Window? window;
    public App()
    {
        UnhandledException += (_, args) => LogFailure(args.Exception);
        InitializeComponent();
    }
    private static void LogFailure(Exception exception)
    {
        try { LocalStore.Save("last-error.json", exception.ToString()); } catch { }
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            string? page = null;
            try
            {
                var activation = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs();
                if (activation.Kind == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.AppNotification &&
                    activation.Data is Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs notification &&
                    notification.Arguments.TryGetValue("page", out var target)) page = target;
            }
            catch { }
            window = new MainWindow(page);
            if (!Environment.GetCommandLineArgs().Any(a => string.Equals(a, "--background", StringComparison.OrdinalIgnoreCase))) window.Activate();
        }
        catch (Exception exception) { LogFailure(exception); throw; }
    }
}
