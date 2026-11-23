using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SkiaSharp;

namespace PixelLift.Windows;

internal readonly record struct ImageSize(int Width, int Height)
{
    public override string ToString() => $"{Width:N0} × {Height:N0} px";

    public ImageSize At(int scale)
    {
        var width = checked(Width * scale);
        var height = checked(Height * scale);
        if (width <= 0 || height <= 0 || width > 16_384 || height > 16_384 || (long)width * height > 32_000_000)
            throw new InvalidOperationException("画像は長辺16,384 px、3,200万画素まで処理できます。倍率を下げてください。");
        return new(width, height);
    }
}

internal static class Images
{
    public const long SourceLimit = 100L * 1024 * 1024;
    public const long CloudLimit = 24L * 1024 * 1024;
    public const long ResultLimit = 128L * 1024 * 1024;
    public static readonly string[] Extensions = [".png", ".jpg", ".jpeg", ".tif", ".tiff", ".webp"];

    public static ImageSize ReadSize(string path, long limit = SourceLimit)
    {
        CheckFile(path, limit);
        using var codec = SKCodec.Create(path);
        if (codec is not null)
            return OrientedSize(codec.Info.Width, codec.Info.Height, codec.EncodedOrigin).At(1);
        using var stream = File.OpenRead(path);
        var frame = ReadTiff(stream);
        return OrientedSize(frame.PixelWidth, frame.PixelHeight, TiffOrigin(frame)).At(1);
    }

    public static BitmapSource Preview(string path, bool fullResolution, long limit = SourceLimit)
    {
        using var image = Decode(path, limit);
        if (fullResolution || Math.Max(image.Width, image.Height) <= 1800) return ToBitmapSource(image);
        var factor = 1800.0 / Math.Max(image.Width, image.Height);
        using var scaled = Resize(image, new(Math.Max(1, (int)(image.Width * factor)), Math.Max(1, (int)(image.Height * factor))));
        return ToBitmapSource(scaled);
    }

    public static void Upscale(string source, int scale, string output, CancellationToken cancellation)
    {
        using var image = Decode(source, SourceLimit);
        cancellation.ThrowIfCancellationRequested();
        using var scaled = Resize(image, new ImageSize(image.Width, image.Height).At(scale));
        cancellation.ThrowIfCancellationRequested();
        SavePng(scaled, output, ResultLimit);
    }

    public static void PrepareCloudImage(string source, string normalized, CancellationToken cancellation)
    {
        using var image = Decode(source, CloudLimit);
        cancellation.ThrowIfCancellationRequested();
        SavePng(image, normalized, CloudLimit);
    }

    public static void NormalizeCloudResult(string path)
    {
        CheckFile(path, ResultLimit);
        using (var codec = SKCodec.Create(path))
            if (codec is { EncodedFormat: SKEncodedImageFormat.Png, EncodedOrigin: SKEncodedOrigin.TopLeft }) return;
        var temporary = $"{path}.normalized";
        try
        {
            using var bitmap = Decode(path, ResultLimit);
            SavePng(bitmap, temporary, ResultLimit);
            File.Move(temporary, path, overwrite: true);
        }
        finally { Storage.DeleteQuietly(temporary); }
    }

    public static string Export(string source, string original, string directory, int scale, string format, int quality)
    {
        var stem = Path.GetFileNameWithoutExtension(original);
        if (stem.Length > 150) stem = stem[..150];
        var extension = format switch { "JPEG" => ".jpg", "TIFF" => ".tif", _ => ".png" };
        var temporary = Path.Combine(directory, $".pixellift-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var target = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write))
            {
                if (format == "PNG")
                {
                    using var input = File.OpenRead(source);
                    input.CopyTo(target);
                }
                else
                {
                    using var bitmap = Decode(source, ResultLimit);
                    if (format == "JPEG")
                    {
                        using var opaque = new SKBitmap(bitmap.Width, bitmap.Height, SKColorType.Bgra8888, SKAlphaType.Opaque);
                        using var canvas = new SKCanvas(opaque);
                        canvas.Clear(SKColors.White);
                        canvas.DrawBitmap(bitmap, 0, 0, new SKSamplingOptions(SKFilterMode.Nearest));
                        using var data = opaque.Encode(SKEncodedImageFormat.Jpeg, Math.Clamp(quality, 5, 100))
                            ?? throw new IOException("JPEGを書き出せませんでした。");
                        data.SaveTo(target);
                    }
                    else
                    {
                        var encoder = new TiffBitmapEncoder { Compression = TiffCompressOption.Zip };
                        encoder.Frames.Add(BitmapFrame.Create(ToBitmapSource(bitmap)));
                        encoder.Save(target);
                    }
                }
            }
            for (var index = 1; index <= 10_000; index++)
            {
                var suffix = index == 1 ? "" : $"_{index}";
                var destination = Path.Combine(directory, $"{stem}_{scale}x{suffix}{extension}");
                try
                {
                    File.Move(temporary, destination, overwrite: false);
                    return destination;
                }
                catch (IOException) when (File.Exists(destination) || Directory.Exists(destination)) { }
            }
            throw new IOException("重複しない保存名を作れませんでした。");
        }
        finally { Storage.DeleteQuietly(temporary); }
    }

    private static void CheckFile(string path, long limit)
    {
        var file = new FileInfo(path);
        if (!file.Exists || file.Length <= 0) throw new IOException("画像ファイルを読み込めません。");
        if (file.Length > limit) throw new IOException($"画像ファイルの上限は {limit / 1024 / 1024} MiB です。");
    }

    private static SKBitmap Decode(string path, long limit)
    {
        CheckFile(path, limit);
        using var codec = SKCodec.Create(path);
        if (codec is not null)
        {
            var size = new ImageSize(codec.Info.Width, codec.Info.Height).At(1);
            var bitmap = new SKBitmap(size.Width, size.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
            if (codec.GetPixels(bitmap.Info, bitmap.GetPixels()) == SKCodecResult.Success)
                return Normalize(bitmap, codec.EncodedOrigin);
            bitmap.Dispose();
            throw new IOException("画像データを読み取れませんでした。");
        }

        using var stream = File.OpenRead(path);
        var frame = ReadTiff(stream);
        var origin = TiffOrigin(frame);
        var dimensions = new ImageSize(frame.PixelWidth, frame.PixelHeight).At(1);
        var converted = new FormatConvertedBitmap(frame, PixelFormats.Pbgra32, null, 0);
        var tiff = new SKBitmap(dimensions.Width, dimensions.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        try
        {
            var pixels = new byte[tiff.ByteCount];
            converted.CopyPixels(pixels, tiff.RowBytes, 0);
            Marshal.Copy(pixels, 0, tiff.GetPixels(), pixels.Length);
        }
        catch
        {
            tiff.Dispose();
            throw;
        }
        return Normalize(tiff, origin);
    }

    private static BitmapFrame ReadTiff(Stream stream)
    {
        try
        {
            var decoder = new TiffBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
            return decoder.Frames[0];
        }
        catch (Exception ex) when (ex is NotSupportedException or FileFormatException or ArgumentException)
        { throw new IOException("PNG、JPEG、TIFF、WebPの画像を選択してください。", ex); }
    }

    private static SKEncodedOrigin TiffOrigin(BitmapFrame frame)
    {
        try
        {
            if (frame.Metadata is BitmapMetadata metadata && metadata.GetQuery("/ifd/{ushort=274}") is ushort value && value is >= 1 and <= 8)
                return (SKEncodedOrigin)value;
        }
        catch (NotSupportedException) { }
        return SKEncodedOrigin.TopLeft;
    }

    private static ImageSize OrientedSize(int width, int height, SKEncodedOrigin origin) =>
        (int)origin >= (int)SKEncodedOrigin.LeftTop ? new(height, width) : new(width, height);

    private static SKBitmap Normalize(SKBitmap bitmap, SKEncodedOrigin origin)
    {
        if (origin == SKEncodedOrigin.TopLeft) return bitmap;
        using (bitmap)
        {
            var w = bitmap.Width;
            var h = bitmap.Height;
            var size = OrientedSize(w, h, origin);
            var result = new SKBitmap(size.Width, size.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var canvas = new SKCanvas(result);
            canvas.Clear(SKColors.Transparent);
            var matrix = origin switch
            {
                SKEncodedOrigin.TopRight => new SKMatrix(-1, 0, w, 0, 1, 0, 0, 0, 1),
                SKEncodedOrigin.BottomRight => new SKMatrix(-1, 0, w, 0, -1, h, 0, 0, 1),
                SKEncodedOrigin.BottomLeft => new SKMatrix(1, 0, 0, 0, -1, h, 0, 0, 1),
                SKEncodedOrigin.LeftTop => new SKMatrix(0, 1, 0, 1, 0, 0, 0, 0, 1),
                SKEncodedOrigin.RightTop => new SKMatrix(0, -1, h, 1, 0, 0, 0, 0, 1),
                SKEncodedOrigin.RightBottom => new SKMatrix(0, -1, h, -1, 0, w, 0, 0, 1),
                SKEncodedOrigin.LeftBottom => new SKMatrix(0, 1, 0, -1, 0, w, 0, 0, 1),
                _ => SKMatrix.Identity
            };
            canvas.SetMatrix(matrix);
            canvas.DrawBitmap(bitmap, 0, 0, new SKSamplingOptions(SKFilterMode.Nearest));
            return result;
        }
    }

    private static SKBitmap Resize(SKBitmap image, ImageSize size) =>
        image.Resize(new SKImageInfo(size.Width, size.Height, SKColorType.Bgra8888, SKAlphaType.Premul),
            new SKSamplingOptions(SKCubicResampler.Mitchell))
        ?? throw new IOException("画像を拡大できませんでした。");

    private static BitmapSource ToBitmapSource(SKBitmap image)
    {
        var source = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Pbgra32, null, image.Bytes, image.RowBytes);
        source.Freeze();
        return source;
    }

    private static void SavePng(SKBitmap bitmap, string path, long limit)
    {
        using var data = bitmap.Encode(SKEncodedImageFormat.Png, 100) ?? throw new IOException("PNGを書き出せませんでした。");
        if (data.Size > limit) throw new IOException($"PNGの容量が {limit / 1024 / 1024} MiB を超えています。");
        using var target = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        data.SaveTo(target);
    }
}
