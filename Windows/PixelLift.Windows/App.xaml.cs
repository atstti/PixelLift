using System.IO;
using System.Windows;

namespace PixelLift.Windows;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args is ["--self-test", var report])
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            try
            {
                await SelfTest.RunAsync(report);
                Shutdown(0);
            }
            catch (Exception ex)
            {
                File.WriteAllText(report, ex.ToString());
                Shutdown(1);
            }
            return;
        }

        try
        {
            MainWindow = new MainWindow(e.Args);
            MainWindow.Show();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "PixelLift AI", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
