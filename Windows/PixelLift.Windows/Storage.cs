using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PixelLift.Windows;

internal sealed record Preferences(bool Cloud = false, int Scale = 2, bool EnhanceFaces = false,
    string Format = "PNG", int JpegQuality = 92, string? ExportFolder = null);

internal sealed class Storage : IDisposable
{
    public const long CacheLimit = 512L * 1024 * 1024;
    private readonly string root;
    private readonly FileStream sessionLock;
    public string Session { get; }
    private string PreferencesPath => Path.Combine(root, "settings.json");
    private string TokenPath => Path.Combine(root, "replicate.key");

    public Storage(string? directory = null)
    {
        root = directory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PixelLiftAI");
        var cache = Path.Combine(root, "cache");
        Directory.CreateDirectory(cache);
        foreach (var old in Directory.EnumerateDirectories(cache, "session-*"))
        {
            try
            {
                using (new FileStream(Path.Combine(old, ".lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                Directory.Delete(old, true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        Session = Path.Combine(cache, $"session-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Session);
        sessionLock = new FileStream(Path.Combine(Session, ".lock"), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
    }

    public Preferences Load()
    {
        try { return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(PreferencesPath)) ?? new(); }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    public void Save(Preferences preferences) =>
        WriteAtomically(PreferencesPath, JsonSerializer.SerializeToUtf8Bytes(preferences));

    public string? GetToken() => File.Exists(TokenPath)
        ? Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(TokenPath), null, DataProtectionScope.CurrentUser))
        : null;

    public void SaveToken(string token)
    {
        token = token.Trim();
        if (token.Length is < 1 or > 512 || token.Any(c => c is < '!' or > '~'))
            throw new InvalidOperationException("ReplicateのAPIキーを確認してください。");
        WriteAtomically(TokenPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(token), null, DataProtectionScope.CurrentUser));
    }

    public void RemoveToken() => File.Delete(TokenPath);

    public long CacheSize => Directory.EnumerateFiles(Session).Sum(path => new FileInfo(path).Length);

    public string ReserveResult()
    {
        if (CacheSize > CacheLimit - 2 * Images.ResultLimit)
            throw new IOException("一時保存領域がいっぱいです。必要な結果を書き出してからキャッシュを削除してください。");
        return Path.Combine(Session, $"{Guid.NewGuid():N}.png");
    }

    public static void DeleteQuietly(string? path)
    {
        if (path is null) return;
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void WriteAtomically(string path, byte[] data)
    {
        var temporary = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, path, overwrite: true);
        }
        finally { DeleteQuietly(temporary); }
    }

    public void Dispose()
    {
        sessionLock.Dispose();
        try { Directory.Delete(Session, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
