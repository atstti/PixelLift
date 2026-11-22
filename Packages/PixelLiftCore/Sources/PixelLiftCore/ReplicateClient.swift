import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol ReplicateTransport: Sendable {
    func response(for request: URLRequest, upload: URL?) async throws -> (Data, HTTPURLResponse)
    func download(_ request: URLRequest, to file: URL, limit: Int) async throws -> HTTPURLResponse
}

final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let originalURL = task.originalRequest?.url, isDeliveryURL(originalURL),
              let targetURL = request.url, isDeliveryURL(targetURL), request.httpMethod == "GET" else {
            completionHandler(nil)
            return
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitized)
    }
}

final class SessionTransport: ReplicateTransport, @unchecked Sendable {
    let session: URLSession
    private let ownsSession: Bool

    init() {
        let settings = URLSessionConfiguration.ephemeral
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 35
        settings.timeoutIntervalForResource = 100
        session = URLSession(configuration: settings, delegate: RedirectPolicy(), delegateQueue: nil)
        ownsSession = true
    }

    init(session: URLSession) {
        self.session = session
        ownsSession = false
    }

    deinit {
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    func response(for request: URLRequest, upload: URL?) async throws -> (Data, HTTPURLResponse) {
        let reply: (Data, URLResponse)
        if let upload {
            reply = try await session.upload(for: request, fromFile: upload)
        } else {
            reply = try await session.data(for: request)
        }
        guard let http = reply.1 as? HTTPURLResponse, reply.0.count <= 1_048_576 else {
            throw PixelLiftError.invalidResponse
        }
        return (reply.0, http)
    }

    func download(_ request: URLRequest, to file: URL, limit: Int) async throws -> HTTPURLResponse {
        #if os(macOS)
        let (bytes, reply) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = reply as? HTTPURLResponse else { throw PixelLiftError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { return http }
        guard http.statusCode != 206 else { throw PixelLiftError.invalidResponse }
        guard http.expectedContentLength <= limit else { throw PixelLiftError.outputTooLarge }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PixelLiftError.fileOperation
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= limit else { throw PixelLiftError.outputTooLarge }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        // URLSession delivers decoded bytes, so Content-Length can describe a different size.
        // URLSession reports transfer errors and the result is subsequently validated as an image.
        guard count > 0 else { throw PixelLiftError.invalidResponse }
        try handle.write(contentsOf: buffer)
        return http
        #else
        let (temporary, reply) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = reply as? HTTPURLResponse else { throw PixelLiftError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { return http }
        guard http.statusCode != 206 else { throw PixelLiftError.invalidResponse }
        guard let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { throw PixelLiftError.invalidResponse }
        guard size <= limit else { throw PixelLiftError.outputTooLarge }
        try FileManager.default.moveItem(at: temporary, to: file)
        return http
        #endif
    }
}

private func isSecure(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
        && (url.port == nil || url.port == 443)
}

func isDeliveryURL(_ url: URL) -> Bool {
    guard isSecure(url), let host = url.host?.lowercased() else { return false }
    return host == "replicate.delivery" || host.hasSuffix(".replicate.delivery")
}

struct ReplicateClient: Sendable {
    static let model = "nightmareai/real-esrgan"
    static let version = "f121d640bd286e1fdc67f9799164c1d5be36ff74576ee11c803ae5b665dd46aa"
    private static let base = URL(string: "https://api.replicate.com/v1/")!

    struct Uploaded: Decodable {
        struct Links: Decodable { let get: URL? }
        let id: String
        let urls: Links?
    }

    struct Prediction: Decodable {
        enum Status: String, Decodable { case starting, processing, succeeded, failed, canceled, aborted }
        let id: String
        let status: Status
        let output: URL?

        private enum CodingKeys: String, CodingKey { case id, status, output }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            status = try values.decode(Status.self, forKey: .status)
            if status != .succeeded {
                output = nil
            } else if let url = try? values.decode(URL.self, forKey: .output) {
                output = url
            } else if let urls = try? values.decode([URL].self, forKey: .output), urls.count == 1 {
                output = urls.first
            } else {
                output = nil
            }
        }
    }

    private struct Creation: Encodable {
        struct Input: Encodable {
            let image: URL
            let scale: Int
            let face_enhance: Bool
        }
        let version: String
        let input: Input
    }

    let token: String
    let transport: any ReplicateTransport
    let pause: @Sendable (Double) async throws -> Void
    let pollingTimeout: Duration

    init(token: String, transport: any ReplicateTransport = SessionTransport(),
         pollingTimeout: Duration = .seconds(600),
         pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) throws {
        guard !token.isEmpty else { throw PixelLiftError.missingToken }
        guard token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw PixelLiftError.invalidToken }
        self.token = token
        self.transport = transport
        self.pause = pause
        self.pollingTimeout = pollingTimeout
    }

    func run(png: URL, output: URL, options: UpscaleOptions,
             progress: @escaping @Sendable (UpscaleStage) async -> Void) async throws {
        var inputID: String?
        var activeID: String?
        var responseStage: UpscaleStage = .uploading
        do {
            await progress(.uploading)
            let input = try await upload(png)
            inputID = input.id
            try FileManager.default.removeItem(at: png)
            let inputPath = "files/\(input.id)"
            let inputURL = input.urls?.get ?? Self.base.appending(path: inputPath)
            guard isSecure(inputURL), inputURL.host?.lowercased() == "api.replicate.com",
                  inputURL.path == "/v1/\(inputPath)" else { throw PixelLiftError.unsafeURL }
            try Task.checkCancellation()
            await progress(.starting)
            try Task.checkCancellation()
            var prediction = try await create(inputURL, options: options)
            guard Self.isID(prediction.id) else { throw PixelLiftError.ambiguousSubmission }
            activeID = prediction.id
            responseStage = .processing
            let deadline = ContinuousClock.now.advanced(by: pollingTimeout)
            while prediction.status == .starting || prediction.status == .processing {
                guard ContinuousClock.now < deadline else { throw PixelLiftError.timedOut }
                try Task.checkCancellation()
                if prediction.status == .processing { await progress(.processing) }
                try await pause(2)
                prediction = try await fetchPrediction(prediction.id)
            }
            activeID = nil
            try Task.checkCancellation()
            switch prediction.status {
            case .succeeded:
                responseStage = .downloading
                await progress(.downloading)
                if prediction.output == nil {
                    try await pause(1)
                    prediction = try await fetchPrediction(prediction.id)
                }
                guard prediction.status == .succeeded, let result = prediction.output else {
                    throw PixelLiftError.predictionOutputUnavailable
                }
                guard isDeliveryURL(result) else { throw PixelLiftError.unsafeURL }
                var downloadRequest = URLRequest(url: result)
                downloadRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                try await retry(safe: true) {
                    do {
                        let response = try await transport.download(downloadRequest, to: output, limit: ImageLimits.resultBytes)
                        try validate(response)
                    } catch {
                        try? FileManager.default.removeItem(at: output)
                        throw error
                    }
                }
            case .failed: throw PixelLiftError.predictionFailed
            case .canceled, .aborted: throw PixelLiftError.predictionCanceled
            case .starting, .processing: throw PixelLiftError.invalidResponse
            }
        } catch {
            let stopped = await cleanup(activeID: activeID, inputID: inputID)
            if !stopped { throw PixelLiftError.cloudCancellationUnconfirmed }
            if (error as? PixelLiftError) == .invalidResponse { throw PixelLiftError.replicateResponse(responseStage) }
            throw error
        }
        _ = await cleanup(activeID: nil, inputID: inputID)
    }

    private func fetchPrediction(_ id: String) async throws -> Prediction {
        let prediction: Prediction = try await decode(request("GET", "predictions/\(id)"))
        guard prediction.id == id else { throw PixelLiftError.invalidResponse }
        return prediction
    }

    private func upload(_ png: URL) async throws -> Uploaded {
        let values = try png.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw PixelLiftError.invalidImage
        }
        guard size <= ImageLimits.cloudBytes else { throw PixelLiftError.inputTooLarge }
        let boundary = UUID().uuidString
        let multipart = png.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: multipart) }
        try Self.writeMultipart(from: png, to: multipart, boundary: boundary)
        var uploadRequest = request("POST", "files")
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let uploaded: Uploaded = try await decode(uploadRequest, upload: multipart)
        // File IDs are opaque and may use base64, including padding. Keep them within one path segment.
        guard !uploaded.id.isEmpty, uploaded.id.utf8.count <= 512,
              uploaded.id.utf8.allSatisfy({ Self.isIDByte($0) || $0 == 43 || $0 == 61 }) else {
            throw PixelLiftError.invalidResponse
        }
        return uploaded
    }

    private func create(_ image: URL, options: UpscaleOptions) async throws -> Prediction {
        let input = Creation.Input(image: image, scale: options.scale.rawValue, face_enhance: options.mode.faceEnhancement)
        var submit = request("POST", "predictions")
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.setValue("10m", forHTTPHeaderField: "Cancel-After")
        submit.httpBody = try JSONEncoder().encode(Creation(version: "\(Self.model):\(Self.version)", input: input))
        do {
            return try await decode(submit)
        } catch let error as PixelLiftError {
            switch error {
            case .unauthorized, .rateLimited, .inputTooLarge, .http(400...499): throw error
            default: throw PixelLiftError.ambiguousSubmission
            }
        } catch {
            throw PixelLiftError.ambiguousSubmission
        }
    }

    private func cleanup(activeID: String?, inputID: String?) async -> Bool {
        guard activeID != nil || inputID != nil else { return true }
        // Cleanup must run even when the queue already canceled the parent task.
        return await Task.detached {
            var stopped = true
            if let id = activeID {
                do {
                    let reply: Prediction = try await decode(request("POST", "predictions/\(id)/cancel"))
                    stopped = reply.id == id && [.canceled, .aborted, .failed, .succeeded].contains(reply.status)
                } catch {
                    stopped = false
                }
            }
            if let id = inputID {
                _ = try? await send(request("DELETE", "files/\(id)"))
            }
            return stopped
        }.value
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.base)!.absoluteURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ request: URLRequest, upload: URL? = nil) async throws -> T {
        let data = try await send(request, upload: upload)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PixelLiftError.invalidResponse }
    }

    private func send(_ request: URLRequest, upload: URL? = nil) async throws -> Data {
        let safe = request.httpMethod == "GET" || request.httpMethod == "DELETE"
        return try await retry(safe: safe) {
            let (data, response) = try await transport.response(for: request, upload: upload)
            try validate(response)
            return data
        }
    }

    private struct Rejection: Error {
        let status: Int
        let retryAfter: Double?
    }

    private func validate(_ response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let value = response.value(forHTTPHeaderField: "Retry-After")
        let seconds = value.flatMap(Double.init).flatMap { $0.isFinite ? max(0, $0) : nil }
        var retryAfter = seconds
        if retryAfter == nil, let value {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            retryAfter = format.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
        }
        throw Rejection(status: response.statusCode, retryAfter: retryAfter)
    }

    private func retry<T>(safe: Bool, operation: () async throws -> T) async throws -> T {
        for attempt in 0...3 {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let rejection as Rejection {
                let backoff = min(16, pow(2, Double(attempt))) + Double.random(in: 0...0.25)
                let delay = max(backoff, rejection.retryAfter ?? 0)
                let retryable = rejection.status == 429 || (safe && [408, 500, 502, 503, 504].contains(rejection.status))
                if retryable && attempt < 3 && delay <= 60 {
                    try await pause(delay)
                    continue
                }
                switch rejection.status {
                case 401, 403: throw PixelLiftError.unauthorized
                case 413: throw PixelLiftError.inputTooLarge
                case 429: throw PixelLiftError.rateLimited
                default: throw PixelLiftError.http(rejection.status)
                }
            } catch PixelLiftError.invalidResponse where safe && attempt < 3 {
                try await pause(pow(2, Double(attempt)) + Double.random(in: 0...0.25))
            } catch let error as URLError {
                if Task.isCancelled { throw CancellationError() }
                let transient: [URLError.Code] = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                                  .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
                if safe && attempt < 3 && transient.contains(error.code) {
                    try await pause(pow(2, Double(attempt)) + Double.random(in: 0...0.25))
                    continue
                }
                throw error.code == .timedOut ? PixelLiftError.timedOut : PixelLiftError.connection
            }
        }
        throw PixelLiftError.invalidResponse
    }

    private static func isID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy(isIDByte)
    }

    private static func isIDByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
    }

    private static func writeMultipart(from png: URL, to file: URL, boundary: String) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PixelLiftError.fileOperation
        }
        let source = try FileHandle(forReadingFrom: png)
        defer { try? source.close() }
        let target = try FileHandle(forWritingTo: file)
        defer { try? target.close() }
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"content\"; filename=\"input.png\"\r\nContent-Type: image/png\r\n\r\n"
        try target.write(contentsOf: Data(header.utf8))
        var copied = 0
        while let chunk = try source.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            copied += chunk.count
            guard copied <= ImageLimits.cloudBytes else { throw PixelLiftError.inputTooLarge }
            try target.write(contentsOf: chunk)
        }
        guard copied > 0 else { throw PixelLiftError.invalidImage }
        try target.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
