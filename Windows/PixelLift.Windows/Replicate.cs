using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace PixelLift.Windows;

internal sealed class Replicate
{
    private const string Version = "nightmareai/real-esrgan:f121d640bd286e1fdc67f9799164c1d5be36ff74576ee11c803ae5b665dd46aa";
    private static readonly Uri Api = new("https://api.replicate.com/v1/");
    private static readonly HttpClient Session = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
    {
        Timeout = Timeout.InfiniteTimeSpan
    };
    private readonly string token;
    private readonly HttpClient client;

    public Replicate(string token, HttpClient? client = null)
    {
        if (string.IsNullOrWhiteSpace(token) || token.Length > 512 || token.Any(c => c is < '!' or > '~'))
            throw new InvalidOperationException("ReplicateのAPIキーを確認してください。");
        this.token = token;
        this.client = client ?? Session;
    }

    public async Task UpscaleAsync(string normalized, string output, int scale, bool enhanceFaces,
        Action<string> progress, CancellationToken cancellation)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromMinutes(11));
        var ct = deadline.Token;
        string? fileId = null;
        string? active = null;
        try
        {
            progress("アップロード中");
            using (var upload = await TryRequestAsync(() => UploadRequest(normalized), retryRead: false, ct))
            {
                var location = upload.Headers.Location;
                using var data = await ReadJsonAsync(upload, ct, allowEmpty: true);
                var id = ReadString(data?.RootElement, "id");
                var link = ReadString(ReadProperty(data?.RootElement, "urls"), "get");
                Uri? uploadedLink = link is null ? location : Uri.TryCreate(Api, link, out var address) ? address : null;
                if (uploadedLink is { IsAbsoluteUri: false }) uploadedLink = new Uri(Api, uploadedLink);
                fileId = ValidId(id) ? id : FileId(uploadedLink);
                if (fileId is null) throw new IOException($"Replicateの画像アップロード応答にファイルIDがありません（HTTP {(int)upload.StatusCode}）。");
                if (uploadedLink is not null && FileId(uploadedLink) != fileId)
                    throw new IOException("Replicateが返した画像URLを確認できません。");
            }

            progress("クラウド処理を開始");
            var inputUri = new Uri(Api, $"files/{Uri.EscapeDataString(fileId)}");
            var payload = JsonSerializer.Serialize(new { version = Version, input = new { image = inputUri.AbsoluteUri, scale, face_enhance = enhanceFaces } });
            (string Id, string Status, Uri? Output) result;
            try
            {
                using var create = await TryRequestAsync(() => {
                    var request = ApiRequest(HttpMethod.Post, "predictions");
                    request.Headers.Add("Cancel-After", "10m");
                    request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
                    return request;
                }, retryRead: false, ct);
                using var json = await ReadJsonAsync(create, ct);
                result = ReadPrediction(json!.RootElement);
            }
            catch (Exception ex) when (ex is IOException or HttpRequestException or JsonException)
            {
                throw new IOException("Replicateの処理開始結果を確認できませんでした。再送前に処理履歴を確認してください。", ex);
            }
            active = result.Id;
            while (result.Status is "starting" or "processing")
            {
                progress("Replicateで処理中");
                await Task.Delay(TimeSpan.FromSeconds(2), ct);
                result = await GetPredictionAsync(active, ct);
            }
            active = null;

            if (result.Status != "succeeded")
                throw new InvalidOperationException(result.Status is "canceled" or "aborted" ? "Replicate側で処理が中止されました。" : "Replicate側で処理が失敗しました。処理履歴を確認してください。");
            if (result.Output is null)
            {
                await Task.Delay(TimeSpan.FromSeconds(1), ct);
                result = await GetPredictionAsync(result.Id, ct);
            }
            if (result.Output is null || !Delivery(result.Output))
                throw new IOException("Replicateの結果画像URLを確認できません。");
            progress("結果をダウンロード中");
            await DownloadAsync(result.Output, output, ct);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new IOException("Replicateの処理がタイムアウトしました。処理履歴を確認してください。");
        }
        catch (HttpRequestException)
        {
            throw new IOException("Replicateに接続できませんでした。ネットワークを確認してください。");
        }
        catch (JsonException)
        {
            throw new IOException("Replicateの応答形式を読み取れませんでした。");
        }
        finally
        {
            if (active is not null) await CleanupAsync(HttpMethod.Post, $"predictions/{Uri.EscapeDataString(active)}/cancel");
            if (fileId is not null) await CleanupAsync(HttpMethod.Delete, $"files/{Uri.EscapeDataString(fileId)}");
        }
    }

    private HttpRequestMessage UploadRequest(string input)
    {
        var request = ApiRequest(HttpMethod.Post, "files");
        var form = new MultipartFormDataContent();
        var file = new StreamContent(File.OpenRead(input));
        file.Headers.ContentType = new MediaTypeHeaderValue("image/png");
        form.Add(file, "content", "input.png");
        request.Content = form;
        return request;
    }

    private HttpRequestMessage ApiRequest(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, new Uri(Api, path));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        return request;
    }

    private async Task<HttpResponseMessage> TryRequestAsync(Func<HttpRequestMessage> factory, bool retryRead, CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            using var request = factory();
            HttpResponseMessage response;
            try
            {
                response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            }
            catch (HttpRequestException) when (retryRead && attempt < 2)
            {
                await Task.Delay(TimeSpan.FromSeconds(1 << attempt), ct);
                continue;
            }
            if (response.IsSuccessStatusCode) return response;
            var code = (int)response.StatusCode;
            var wait = response.Headers.RetryAfter?.Delta
                ?? (response.Headers.RetryAfter?.Date is DateTimeOffset date ? date - DateTimeOffset.UtcNow : TimeSpan.FromSeconds(1 << attempt));
            response.Dispose();
            if (attempt < 2 && wait <= TimeSpan.FromSeconds(30) && (code == 429 || (retryRead && code is 408 or 500 or 502 or 503 or 504)))
            {
                await Task.Delay(wait > TimeSpan.Zero ? wait : TimeSpan.Zero, ct);
                continue;
            }
            throw code switch
            {
                401 or 403 => new InvalidOperationException("ReplicateのAPIキーとアカウントを確認してください。"),
                402 => new InvalidOperationException("Replicateで支払いが必要です。請求設定とクレジット残高を確認してください（HTTP 402）。"),
                413 => new InvalidOperationException("Replicateに送信できる画像容量を超えています。"),
                429 => new InvalidOperationException("Replicateの利用制限に達しました。少し待って再試行してください。"),
                >= 500 => new IOException($"Replicateで一時的なエラーが発生しました（HTTP {code}）。"),
                _ => new InvalidOperationException($"ReplicateがHTTP {code}を返しました。")
            };
        }
    }

    private async Task<(string Id, string Status, Uri? Output)> GetPredictionAsync(string id, CancellationToken ct)
    {
        using var reply = await TryRequestAsync(() => ApiRequest(HttpMethod.Get, $"predictions/{Uri.EscapeDataString(id)}"), retryRead: true, ct);
        using var json = await ReadJsonAsync(reply, ct);
        var result = ReadPrediction(json!.RootElement);
        if (result.Id != id) throw new IOException("Replicateの処理IDを確認できません。");
        return result;
    }

    private async Task DownloadAsync(Uri address, string path, CancellationToken ct)
    {
        for (var i = 0; i < 6; i++)
        {
            if (!Delivery(address)) throw new IOException("Replicateの配信用URLを確認できません。");
            using var request = new HttpRequestMessage(HttpMethod.Get, address);
            using var reply = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if ((int)reply.StatusCode is 301 or 302 or 303 or 307 or 308 && reply.Headers.Location is Uri next)
            {
                address = next.IsAbsoluteUri ? next : new Uri(address, next);
                continue;
            }
            if (reply.StatusCode != HttpStatusCode.OK) throw new IOException($"Replicateの画像を受信できませんでした（HTTP {(int)reply.StatusCode}）。");
            await using var target = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65_536, useAsync: true);
            await CopyAsync(reply.Content, target, Images.ResultLimit, ct);
            if (target.Length <= 0) throw new IOException("Replicateの結果が空でした。");
            return;
        }
        throw new IOException("Replicateの配信用URLで転送回数が上限を超えました。");
    }

    private async Task CleanupAsync(HttpMethod method, string path)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(6));
            using var request = ApiRequest(method, path);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        }
        catch (HttpRequestException) { }
        catch (OperationCanceledException) { }
    }

    private static async Task<JsonDocument?> ReadJsonAsync(HttpResponseMessage response, CancellationToken ct, bool allowEmpty = false)
    {
        using var buffer = new MemoryStream();
        await CopyAsync(response.Content, buffer, 1_048_576, ct);
        if (buffer.Length == 0 && allowEmpty) return null;
        buffer.Position = 0;
        return await JsonDocument.ParseAsync(buffer, cancellationToken: ct);
    }

    private static async Task CopyAsync(HttpContent content, Stream target, long limit, CancellationToken ct)
    {
        if (content.Headers.ContentLength > limit) throw new IOException("Replicateの応答が容量上限を超えました。");
        await using var source = await content.ReadAsStreamAsync(ct);
        var bytes = new byte[65_536];
        long total = 0;
        while (await source.ReadAsync(bytes, ct) is var count && count > 0)
        {
            total += count;
            if (total > limit) throw new IOException("Replicateの応答が容量上限を超えました。");
            await target.WriteAsync(bytes.AsMemory(0, count), ct);
        }
    }

    private static (string Id, string Status, Uri? Output) ReadPrediction(JsonElement json)
    {
        var id = ReadString(json, "id");
        var status = ReadString(json, "status");
        if (!ValidId(id) || status is not ("starting" or "processing" or "succeeded" or "failed" or "aborted" or "canceled"))
            throw new IOException("Replicateの処理応答を読み取れませんでした。");
        var output = ReadProperty(json, "output");
        if (output is { ValueKind: JsonValueKind.Array } array && array.GetArrayLength() == 1) output = array[0];
        var url = output is { ValueKind: JsonValueKind.String } value && Uri.TryCreate(value.GetString(), UriKind.Absolute, out var address)
            ? address : null;
        return (id!, status, url);
    }

    private static JsonElement? ReadProperty(JsonElement? json, string name) =>
        json is { ValueKind: JsonValueKind.Object } obj && obj.TryGetProperty(name, out var value) ? value : null;

    private static string? ReadString(JsonElement? json, string name) =>
        ReadProperty(json, name) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;

    private static bool Secure(Uri address) => address.IsAbsoluteUri && address.Scheme == "https" && address.Port == 443 && address.UserInfo == "";

    private static bool Delivery(Uri address) =>
        Secure(address) && (address.Host == "replicate.delivery" || address.Host.EndsWith(".replicate.delivery", StringComparison.OrdinalIgnoreCase));

    private static bool ValidId(string? id) =>
        id is { Length: > 0 and <= 512 } && id is not ("." or "..") && id.All(c => char.IsAsciiLetterOrDigit(c) || "-_+=.~".Contains(c));

    private static string? FileId(Uri? address)
    {
        const string prefix = "/v1/files/";
        if (address is null || !Secure(address) || address.Host != Api.Host || !address.AbsolutePath.StartsWith(prefix, StringComparison.Ordinal))
            return null;
        var id = Uri.UnescapeDataString(address.AbsolutePath[prefix.Length..]);
        return ValidId(id) ? id : null;
    }
}
