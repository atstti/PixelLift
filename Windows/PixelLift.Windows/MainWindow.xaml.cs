using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace PixelLift.Windows;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<Row> rows = [];
    private readonly Storage storage;
    private readonly SemaphoreSlim previewGate = new(1);
    private Preferences settings;
    private CancellationTokenSource? processing;
    private CancellationTokenSource? preview;
    private bool saving;
    private bool adding;
    private bool initialized;
    private bool closeAfterOperation;
    private bool closed;
    private string? statusOverride;
    private ImageSize? previewSize;
    private Row? Selected => FileList.SelectedItem as Row;
    private bool Busy => processing is not null || saving || adding;

    internal MainWindow(string[] files, Storage? testStorage = null)
    {
        storage = testStorage ?? new();
        settings = storage.Load();
        InitializeComponent();
        FileList.ItemsSource = rows;
        Provider.ItemsSource = new[] { "ローカル補間（Mock）", "Replicate" };
        Scale.ItemsSource = new[] { "2倍", "4倍", "8倍" };
        Format.ItemsSource = new[] { "PNG", "JPEG", "TIFF" };
        Zoom.ItemsSource = new[] { "全体表示", "100%", "200%", "400%" };
        Provider.SelectedIndex = settings.Cloud ? 1 : 0;
        Scale.SelectedIndex = settings.Scale switch { 4 => 1, 8 => 2, _ => 0 };
        Format.SelectedItem = settings.Format;
        if (Format.SelectedIndex < 0) Format.SelectedIndex = 0;
        Enhance.IsChecked = settings.EnhanceFaces;
        JpegQuality.Value = settings.JpegQuality;
        Zoom.SelectedIndex = 0;
        initialized = true;
        Refresh();
        if (files.Length > 0) Loaded += async (_, _) => await AddAsync(files);
    }

    private async void AddFilesClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "画像を追加", Filter = "画像|*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.webp", Multiselect = true };
        if (!Busy && dialog.ShowDialog(this) == true) await AddAsync(dialog.FileNames);
    }

    private void FilesDragged(object sender, DragEventArgs e)
    {
        e.Effects = !Busy && e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private async void FilesDropped(object sender, DragEventArgs e)
    {
        if (!Busy && e.Data.GetData(DataFormats.FileDrop) is string[] files) await AddAsync(files);
    }

    internal async Task AddAsync(IEnumerable<string> paths)
    {
        if (Busy) return;
        adding = true;
        statusOverride = "画像を読み込み中";
        Refresh();
        try
        {
            var candidates = paths.Where(path => Images.Extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase))
                .Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase)
                .Where(path => rows.All(row => !string.Equals(row.Path, path, StringComparison.OrdinalIgnoreCase))).ToArray();
            var loaded = await Task.Run(() =>
            {
                var items = new List<Row>();
                var errors = new List<string>();
                foreach (var path in candidates)
                {
                    try { items.Add(new(path, Images.ReadSize(path))); }
                    catch (Exception ex) { errors.Add($"{Path.GetFileName(path)}：{ex.Message}"); }
                }
                return (items, errors);
            });
            foreach (var row in loaded.items) rows.Add(row);
            if (Selected is null && rows.Count > 0) FileList.SelectedIndex = 0;
            statusOverride = loaded.errors.Count > 0 ? loaded.errors[0]
                : loaded.items.Count == 0 ? "追加できる画像がありませんでした。" : null;
        }
        catch (Exception ex) { statusOverride = ex.Message; }
        finally
        {
            adding = false;
            FinishOperation();
        }
    }

    private void RemoveClicked(object sender, RoutedEventArgs e)
    {
        if (Busy || Selected is not { } row) return;
        Storage.DeleteQuietly(row.Result);
        var index = rows.IndexOf(row);
        rows.Remove(row);
        if (rows.Count > 0) FileList.SelectedIndex = Math.Min(index, rows.Count - 1);
        statusOverride = null;
        Refresh();
    }

    private void ClearClicked(object sender, RoutedEventArgs e)
    {
        if (Busy || MessageBox.Show(this, "このウィンドウの一時結果を削除します。書き出した画像は保持されます。",
            "キャッシュを削除", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        ResetPreview();
        foreach (var row in rows)
        {
            Storage.DeleteQuietly(row.Result);
            row.Result = null;
            row.Status = "未処理";
            row.Error = null;
        }
        statusOverride = "キャッシュを削除しました。";
        Refresh();
        _ = LoadPreviewAsync();
    }

    private void SettingsChanged(object sender, RoutedEventArgs e)
    {
        if (!initialized) return;
        settings = settings with
        {
            Cloud = Provider.SelectedIndex == 1,
            Scale = Scale.SelectedIndex switch { 1 => 4, 2 => 8, _ => 2 },
            EnhanceFaces = Enhance.IsChecked == true,
            Format = Format.SelectedItem as string ?? "PNG",
            JpegQuality = (int)JpegQuality.Value
        };
        SaveSettings();
        Refresh();
    }

    private void SaveSettings()
    {
        try { storage.Save(settings); }
        catch (Exception ex) { statusOverride = $"設定を保存できませんでした。{ex.Message}"; }
    }

    private void TokenClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new TokenWindow(storage) { Owner = this };
        dialog.ShowDialog();
        Refresh();
    }

    private void BillingClicked(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("https://replicate.com/account/billing") { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "請求設定"); }
    }

    private void FolderClicked(object sender, RoutedEventArgs e) => EnsureFolder(force: true);

    private string? EnsureFolder(bool force = false)
    {
        if (!force && settings.ExportFolder is { } saved && Directory.Exists(saved)) return saved;
        var dialog = new OpenFolderDialog { Title = "書き出し先フォルダーを選択" };
        if (settings.ExportFolder is { } previous && Directory.Exists(previous)) dialog.InitialDirectory = previous;
        if (dialog.ShowDialog(this) != true) return null;
        settings = settings with { ExportFolder = dialog.FolderName };
        SaveSettings();
        Refresh();
        return dialog.FolderName;
    }

    private async void ProcessAllClicked(object sender, RoutedEventArgs e) =>
        await ProcessAsync(rows.Where(row => row.Result is null || row.Error is not null).ToArray());

    private async void ProcessSelectedClicked(object sender, RoutedEventArgs e)
    {
        if (Selected is { } row) await ProcessAsync([row]);
    }

    internal async Task ProcessAsync(Row[] batch)
    {
        if (Busy || batch.Length == 0) return;
        var options = settings;
        Replicate? cloud = null;
        if (options.Cloud)
        {
            try { cloud = new Replicate(storage.GetToken() ?? ""); }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "Replicate の設定");
                return;
            }
            if (MessageBox.Show(this, $"{batch.Length} 枚の画像を Replicate に送信します。\nReplicate の利用料金がかかる場合があります。",
                "クラウド処理", MessageBoxButton.OKCancel, MessageBoxImage.Information) != MessageBoxResult.OK) return;
        }
        using var cancellation = new CancellationTokenSource();
        processing = cancellation;
        foreach (var row in batch)
        {
            row.Status = "処理待ち";
            row.Error = null;
        }
        var done = 0;
        var failed = 0;
        var canceled = 0;
        Refresh();
        try
        {
            foreach (var row in batch)
            {
                if (cancellation.IsCancellationRequested)
                {
                    row.Status = "中止";
                    canceled++;
                    continue;
                }
                string? result = null;
                string? normalized = null;
                try
                {
                    var expected = row.Size.At(options.Scale);
                    result = storage.ReserveResult();
                    row.Status = "処理中";
                    statusOverride = $"{row.Name} を処理中";
                    Refresh();
                    var outputPath = result;
                    if (cloud is null)
                    {
                        await Task.Run(() => Images.Upscale(row.Path, options.Scale, outputPath, cancellation.Token), cancellation.Token);
                    }
                    else
                    {
                        normalized = Path.Combine(storage.Session, $"{Guid.NewGuid():N}.input.png");
                        var inputPath = normalized;
                        await Task.Run(() => Images.PrepareCloudImage(row.Path, inputPath, cancellation.Token), cancellation.Token);
                        var progress = new Progress<string>(text =>
                        {
                            if (processing == cancellation && row.Status == "処理中")
                            {
                                statusOverride = text;
                                Refresh();
                            }
                        });
                        await Task.Run(() => cloud.UpscaleAsync(inputPath, outputPath, options.Scale, options.EnhanceFaces,
                            text => ((IProgress<string>)progress).Report(text), cancellation.Token), cancellation.Token);
                        Storage.DeleteQuietly(normalized);
                        normalized = null;
                        await Task.Run(() => Images.NormalizeCloudResult(outputPath), cancellation.Token);
                    }
                    cancellation.Token.ThrowIfCancellationRequested();
                    if (await Task.Run(() => Images.ReadSize(outputPath, Images.ResultLimit)) != expected)
                        throw new InvalidOperationException("処理結果の解像度が指定倍率と一致しません。");
                    Storage.DeleteQuietly(row.Result);
                    row.Result = result;
                    row.Scale = options.Scale;
                    row.ResultProvider = cloud is null ? "ローカル補間" : "Replicate";
                    row.Status = "完了";
                    result = null;
                    done++;
                }
                catch (OperationCanceledException)
                {
                    row.Status = "中止";
                    canceled++;
                }
                catch (Exception ex)
                {
                    row.Status = "失敗";
                    row.Error = ex.Message;
                    failed++;
                }
                finally
                {
                    Storage.DeleteQuietly(result);
                    Storage.DeleteQuietly(normalized);
                    if (Selected == row)
                    {
                        Refresh();
                        _ = LoadPreviewAsync();
                    }
                }
            }
            statusOverride = $"完了 {done} 件  ·  失敗 {failed} 件  ·  中止 {canceled} 件";
        }
        finally
        {
            processing = null;
            FinishOperation();
        }
    }

    private void CancelClicked(object sender, RoutedEventArgs e)
    {
        processing?.Cancel();
        statusOverride = "処理を中止しています…";
        Refresh();
    }

    private async void SaveAllClicked(object sender, RoutedEventArgs e) => await SaveAsync(rows.Where(row => row.Result is not null).ToArray());

    private async void SaveSelectedClicked(object sender, RoutedEventArgs e)
    {
        if (Selected is { Result: not null } row) await SaveAsync([row]);
    }

    internal async Task SaveAsync(Row[] batch)
    {
        if (Busy || batch.Length == 0 || EnsureFolder() is not { } directory) return;
        saving = true;
        statusOverride = "書き出し中";
        Refresh();
        var options = settings;
        try
        {
            var report = await Task.Run(() =>
            {
                var count = 0;
                var errors = new List<string>();
                foreach (var row in batch)
                {
                    try { Images.Export(row.Result!, row.Name, directory, row.Scale, options.Format, options.JpegQuality); count++; }
                    catch (Exception ex) { errors.Add($"{row.Name}：{ex.Message}"); }
                }
                return (count, errors);
            });
            statusOverride = $"保存 {report.count} 件  ·  {directory}";
            if (report.errors.Count > 0) MessageBox.Show(this, string.Join("\n", report.errors.Take(6)), "書き出し結果");
        }
        finally
        {
            saving = false;
            FinishOperation();
        }
    }

    private void SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized) return;
        Refresh();
        _ = LoadPreviewAsync();
    }

    private void ZoomChanged(object sender, SelectionChangedEventArgs e)
    {
        if (initialized) _ = LoadPreviewAsync();
    }

    private void ResetPreview()
    {
        preview?.Cancel();
        previewSize = null;
        BeforeImage.Source = AfterImage.Source = null;
        PreviewFrame.Width = PreviewFrame.Height = 0;
        CompareControls.Visibility = Visibility.Collapsed;
        Divider.Visibility = Visibility.Collapsed;
    }

    private async Task LoadPreviewAsync()
    {
        ResetPreview();
        if (Selected is not { } row)
        {
            EmptyPreview.Visibility = Visibility.Visible;
            return;
        }
        EmptyPreview.Visibility = Visibility.Collapsed;
        var resolvedResult = row.Result;
        var displaySize = resolvedResult is null ? row.Size : row.Size.At(row.Scale);
        var fullResolution = Zoom.SelectedIndex > 0;
        using var cancellation = new CancellationTokenSource();
        preview = cancellation;
        try
        {
            await previewGate.WaitAsync(cancellation.Token);
            try
            {
                var images = await Task.Run(() =>
                {
                    var before = Images.Preview(row.Path, fullResolution);
                    cancellation.Token.ThrowIfCancellationRequested();
                    var after = resolvedResult is null ? null : Images.Preview(resolvedResult, fullResolution, Images.ResultLimit);
                    return (before, after);
                }, cancellation.Token);
                if (!cancellation.IsCancellationRequested && !closed)
                {
                    BeforeImage.Source = images.before;
                    AfterImage.Source = images.after;
                    previewSize = displaySize;
                    CompareControls.Visibility = images.after is null ? Visibility.Collapsed : Visibility.Visible;
                    Divider.Visibility = CompareControls.Visibility;
                    ResizePreview();
                }
            }
            finally { previewGate.Release(); }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (!cancellation.IsCancellationRequested && !closed)
            {
                statusOverride = $"プレビューを表示できません。{ex.Message}";
                Refresh();
            }
        }
        finally { if (preview == cancellation) preview = null; }
    }

    private void PreviewResized(object sender, SizeChangedEventArgs e) => ResizePreview();
    private void SplitChanged(object sender, RoutedPropertyChangedEventArgs<double> e) => PositionDivider();

    private void ResizePreview()
    {
        if (!initialized || previewSize is not ImageSize size) return;
        var dpi = VisualTreeHelper.GetDpi(this);
        var ratio = Zoom.SelectedIndex switch
        {
            1 => 1.0 / dpi.DpiScaleX,
            2 => 2.0 / dpi.DpiScaleX,
            3 => 4.0 / dpi.DpiScaleX,
            _ => Math.Min(Math.Max(1, PreviewScroll.ActualWidth - 22) / size.Width,
                Math.Max(1, PreviewScroll.ActualHeight - 22) / size.Height)
        };
        PreviewFrame.Width = size.Width * ratio;
        PreviewFrame.Height = size.Height * ratio;
        PositionDivider();
    }

    private void PositionDivider()
    {
        if (!initialized || AfterImage.Source is null) return;
        var x = PreviewFrame.Width * Split.Value;
        AfterImage.Clip = new RectangleGeometry(new Rect(x, 0, PreviewFrame.Width - x, PreviewFrame.Height));
        Divider.Height = PreviewFrame.Height;
        Canvas.SetLeft(Divider, Math.Clamp(x - 1, 0, PreviewFrame.Width));
    }

    private void Refresh()
    {
        if (!initialized) return;
        CloudSettings.Visibility = settings.Cloud ? Visibility.Visible : Visibility.Collapsed;
        ProviderNote.Text = settings.Cloud ? "画像を Replicate へ送信して高画質化します。" : "画像の質感を残しやすいローカル補間です。オフラインで使えます。";
        JpegOptions.Visibility = settings.Format == "JPEG" ? Visibility.Visible : Visibility.Collapsed;
        QualityText.Text = $"JPEG 品質 {settings.JpegQuality}%";
        FolderText.Text = settings.ExportFolder ?? "保存時にフォルダーを選択";
        FolderText.ToolTip = settings.ExportFolder;
        Provider.IsEnabled = Scale.IsEnabled = Format.IsEnabled = Enhance.IsEnabled = JpegQuality.IsEnabled = !Busy;
        RemoveButton.IsEnabled = ProcessSelectedButton.IsEnabled = !Busy && Selected is not null;
        SaveSelectedButton.IsEnabled = !Busy && Selected?.Result is not null;
        ClearButton.IsEnabled = SaveAllButton.IsEnabled = !Busy && rows.Any(row => row.Result is not null);
        ProcessAllButton.IsEnabled = !Busy && rows.Any(row => row.Result is null || row.Error is not null);
        CancelButton.IsEnabled = processing is { IsCancellationRequested: false };
        if (Selected is { } row)
        {
            SelectionInfo.Text = row.Result is null ? $"元画像  {row.Size}" : $"元画像  {row.Size}\n結果  {row.Size.At(row.Scale)}\n{row.ResultProvider}";
            SelectionError.Text = row.Error ?? "";
        }
        else { SelectionInfo.Text = SelectionError.Text = ""; }
        StatusLine.Text = statusOverride ?? $"{rows.Count} 枚  ·  処理済み {rows.Count(row => row.Result is not null)} 枚";
    }

    private void FinishOperation()
    {
        Refresh();
        if (closeAfterOperation && !Busy) Close();
    }

    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (!Busy) return;
        e.Cancel = true;
        closeAfterOperation = true;
        processing?.Cancel();
    }

    private void WindowClosed(object? sender, EventArgs e)
    {
        closed = true;
        preview?.Cancel();
        storage.Dispose();
    }

    internal IReadOnlyList<Row> Items => rows;
}

internal sealed class Row(string path, ImageSize size) : INotifyPropertyChanged
{
    public string Path { get; } = path;
    public string Name { get; } = System.IO.Path.GetFileName(path);
    public ImageSize Size { get; } = size;
    public string? Result { get; set; }
    public int Scale { get; set; }
    public string? ResultProvider { get; set; }
    public string? Error { get; set; }
    public event PropertyChangedEventHandler? PropertyChanged;
    private string status = "未処理";

    public string Status
    {
        get => status;
        set { if (status != value) { status = value; Notify(); } }
    }

    private void Notify([CallerMemberName] string? member = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(member));
}
