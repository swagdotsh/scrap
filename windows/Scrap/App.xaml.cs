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
            window = new MainWindow();
            window.Activate();
        }
        catch (Exception exception) { LogFailure(exception); throw; }
    }
}
