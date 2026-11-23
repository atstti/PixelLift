using System.IO;
using System.Net;
using System.Net.Http;
using System.Windows;
using System.Windows.Media.Imaging;
using SkiaSharp;

namespace PixelLift.Windows;

internal static class SelfTest
{
    public static async Task RunAsync(string report)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"PixelLift-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var source = Path.Combine(directory, "sample.png");
            var webp = Path.Combine(directory, "sample.webp");
            using (var bitmap = new SKBitmap(12, 8))
            {
                bitmap.Erase(SKColors.SeaGreen);
                bitmap.SetPixel(0, 0, SKColors.Salmon);
                using var pngData = bitmap.Encode(SKEncodedImageFormat.Png, 100);
                using var webpData = bitmap.Encode(SKEncodedImageFormat.Webp, 100);
                File.WriteAllBytes(source, pngData.ToArray());
                File.WriteAllBytes(webp, webpData.ToArray());
            }

            var checkedResults = new List<string>();
            Expect(Images.ReadSize(source) == new ImageSize(12, 8), "PNG import");
            Expect(Images.ReadSize(webp) == new ImageSize(12, 8), "WebP import");
            checkedResults.Add("PNG/WebP import");

            foreach (var scale in new[] { 2, 4, 8 })
            {
                var result = Path.Combine(directory, $"local-{scale}.png");
                Images.Upscale(source, scale, result, CancellationToken.None);
                Expect(Images.ReadSize(result) == new ImageSize(12 * scale, 8 * scale), $"local scale {scale}");
                foreach (var format in new[] { "PNG", "JPEG", "TIFF" })
                {
                    var first = Images.Export(result, source, directory, scale, format, 92);
                    var second = Images.Export(result, source, directory, scale, format, 92);
                    Expect(first != second && File.Exists(first) && File.Exists(second), $"non-destructive {format} export");
                    var preview = Images.Preview(first, true);
                    Expect(preview.PixelWidth == 12 * scale && preview.PixelHeight == 8 * scale, $"decode {format} export");
                }
            }
            checkedResults.Add("2x/4x/8x local resize and non-destructive PNG/JPEG/TIFF export");

            var rotated = Path.Combine(directory, "rotated.jpg");
            using (var output = File.Create(rotated))
            {
                var metadata = new BitmapMetadata("jpg");
                metadata.SetQuery("/app1/ifd/{ushort=274}", (ushort)6);
                var jpeg = new JpegBitmapEncoder();
                jpeg.Frames.Add(BitmapFrame.Create(Images.Preview(source, true), null, metadata, null));
                jpeg.Save(output);
            }
            Expect(Images.ReadSize(rotated) == new ImageSize(8, 12), "JPEG EXIF orientation metadata");
            var rotatedPreview = Images.Preview(rotated, true);
            Expect(rotatedPreview.PixelWidth == 8 && rotatedPreview.PixelHeight == 12, "rotated pixels");
            checkedResults.Add("JPEG EXIF orientation");

            using (var storage = new Storage(Path.Combine(directory, "credentials")))
            {
                Expect(!storage.Load().Cloud, "offline is the default");
                storage.SaveToken("fixture-token");
                Expect(storage.GetToken() == "fixture-token", "DPAPI round trip");
                Expect(!File.ReadAllBytes(Path.Combine(directory, "credentials", "replicate.key")).AsSpan().ContainsSequence("fixture-token"u8),
                    "token not stored in clear text");
                storage.RemoveToken();
                Expect(storage.GetToken() is null, "token removed");
            }
            checkedResults.Add("offline defaults and encrypted API key storage");

            using (var http = new HttpClient(new ReplicateStub(File.ReadAllBytes(Path.Combine(directory, "local-2.png")))))
            {
                var normalized = Path.Combine(directory, "normalized.png");
                var result = Path.Combine(directory, "cloud.png");
                Images.PrepareCloudImage(source, normalized, CancellationToken.None);
                await new Replicate("fixture-token", http).UpscaleAsync(normalized, result, 2, false, _ => { }, CancellationToken.None);
                Expect(Images.ReadSize(result) == new ImageSize(24, 16), "downloaded image");
            }
            using (var http = new HttpClient(new BillingStub()))
            {
                try
                {
                    await new Replicate("fixture-token", http).UpscaleAsync(source, Path.Combine(directory, "unused.png"), 2, false, _ => { }, CancellationToken.None);
                    throw new Exception("Expected a billing error");
                }
                catch (InvalidOperationException ex) when (ex.Message.Contains("HTTP 402", StringComparison.Ordinal)) { }
            }
            checkedResults.Add("stubbed Replicate upload, processing, download, and HTTP 402");

            var configuration = new Storage(Path.Combine(directory, "window"));
            configuration.Save(new Preferences(ExportFolder: directory));
            var window = new MainWindow([], configuration);
            window.Measure(new Size(1200, 760));
            window.Arrange(new Rect(0, 0, 1200, 760));
            try
            {
                await window.AddAsync([source, webp]);
                await window.ProcessAsync(window.Items.ToArray());
                Expect(window.Items.Count == 2 && window.Items.All(row => row.Result is not null), "two-image UI batch");
                await window.SaveAsync(window.Items.ToArray());
                Expect(Directory.EnumerateFiles(directory, "sample_2x*.png").Count() >= 4, "batch outputs");
            }
            finally { window.Close(); }
            checkedResults.Add("WPF window, two-image batch, and batch export");

            File.WriteAllLines(report, checkedResults.Select(line => $"PASS {line}"));
        }
        finally
        {
            try { Directory.Delete(directory, true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException($"Self-test failed: {message}");
    }

    private sealed class ReplicateStub(byte[] png) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var url = request.RequestUri!;
            if (url.Host == "replicate.delivery")
            {
                Expect(request.Headers.Authorization is null && request.Method == HttpMethod.Get, "no credential on result request");
                return new(HttpStatusCode.OK) { Content = new ByteArrayContent(png) };
            }
            Expect(url.Host == "api.replicate.com" && request.Headers.Authorization?.Parameter == "fixture-token", "API request destination");
            switch (request.Method.Method, url.AbsolutePath)
            {
                case ("POST", "/v1/files"):
                    var content = await request.Content!.ReadAsByteArrayAsync(cancellationToken);
                    Expect(content.AsSpan().ContainsSequence("input.png"u8), "multipart image");
                    return new(HttpStatusCode.Created) { Content = new StringContent("""{"id":"upload1","urls":{"get":"https://api.replicate.com/v1/files/upload1"}}""") };
                case ("POST", "/v1/predictions"):
                    var json = await request.Content!.ReadAsStringAsync(cancellationToken);
                    Expect(json.Contains("https://api.replicate.com/v1/files/upload1", StringComparison.Ordinal), "uploaded file link");
                    return new(HttpStatusCode.Created) { Content = new StringContent("""{"id":"job1","status":"processing","output":null}""") };
                case ("GET", "/v1/predictions/job1"):
                    return new(HttpStatusCode.OK) { Content = new StringContent("""{"id":"job1","status":"succeeded","output":"https://replicate.delivery/result.png"}""") };
                case ("DELETE", "/v1/files/upload1"):
                    return new(HttpStatusCode.NoContent);
                default: throw new InvalidOperationException("Unexpected stub request.");
            }
        }
    }

    private sealed class BillingStub : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Expect(request.RequestUri?.AbsolutePath == "/v1/files", "billing block before prediction");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.PaymentRequired));
        }
    }

    private static bool ContainsSequence(this Span<byte> source, ReadOnlySpan<byte> value) => source.IndexOf(value) >= 0;
}
