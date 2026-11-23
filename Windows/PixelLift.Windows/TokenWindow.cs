using System.Windows;
using System.Windows.Controls;

namespace PixelLift.Windows;

internal sealed class TokenWindow : Window
{
    public TokenWindow(Storage storage)
    {
        Title = "Replicate の API キー";
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        var body = new StackPanel { Margin = new Thickness(20) };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) };
        try { status.Text = storage.GetToken() is null ? "API キーは未設定です。" : "API キーを保存済みです。"; }
        catch { status.Text = "API キーを読み取れません。貼り付け直してください。"; }
        body.Children.Add(status);
        var password = new PasswordBox { MinHeight = 28, Margin = new Thickness(0, 0, 0, 12) };
        System.Windows.Automation.AutomationProperties.SetName(password, "Replicate API キー");
        body.Children.Add(password);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        Button ButtonFor(string label) => new() { Content = label, MinWidth = 84, MinHeight = 30, Margin = new Thickness(8, 0, 0, 0) };
        var close = ButtonFor("閉じる");
        close.IsCancel = true;
        var remove = ButtonFor("削除");
        var save = ButtonFor("保存");
        save.IsDefault = true;
        save.Click += (_, _) =>
        {
            try
            {
                storage.SaveToken(password.Password);
                password.Clear();
                DialogResult = true;
            }
            catch (Exception ex) { status.Text = ex.Message; }
        };
        remove.Click += (_, _) =>
        {
            try
            {
                storage.RemoveToken();
                password.Clear();
                status.Text = "API キーを削除しました。";
            }
            catch (Exception ex) { status.Text = ex.Message; }
        };
        buttons.Children.Add(close);
        buttons.Children.Add(remove);
        buttons.Children.Add(save);
        body.Children.Add(buttons);
        Content = body;
        Loaded += (_, _) => password.Focus();
    }
}
