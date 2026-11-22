import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PixelLiftCore

final class ReplicateTests: XCTestCase {
    private let options = UpscaleOptions(scale: .eight, mode: .preserveFaces)
    private let start = #"{"id":"job1","status":"starting","output":null}"#
    private let processing = #"{"id":"job1","status":"processing","output":null}"#
    private let upload = #"{"id":"file1","urls":{"get":"https://api.replicate.com/v1/files/file1"}}"#
    private let success = #"{"id":"job1","status":"succeeded","output":"https://replicate.delivery/result.png"}"#

    func testUploadCreationRateLimitPollingDownloadAndCleanup() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([
            .init("POST /v1/files", 201, upload),
            .init("POST /v1/predictions", 429, headers: ["Retry-After": "3"]),
            .init("POST /v1/predictions", 201, start),
            .init("GET /v1/predictions/job1", 502),
            .init("GET /v1/predictions/job1", 200, processing),
            .init("GET /v1/predictions/job1", 200, success),
            .init("GET /result.png", 200, "test-output"),
            .init("DELETE /v1/files/file1", 204)
        ])
        let delays = Trace<Double>()
        let stages = Trace<UpscaleStage>()
        let client = try ReplicateClient(token: "unit-test-token", transport: transport) { delay in
            await delays.add(delay)
        }
        try await client.run(png: png, output: result, options: options) { stage in await stages.add(stage) }

        let records = await transport.records
        let pending = await transport.remaining
        let recordedDelays = await delays.items
        let recordedStages = await stages.items
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(recordedDelays.first, 3)
        XCTAssertEqual(recordedStages, [.uploading, .starting, .processing, .downloading])
        XCTAssertEqual(try Data(contentsOf: result), Data("test-output".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
        XCTAssertEqual(records.last?.request.httpMethod, "DELETE")
        XCTAssertEqual(records[6].request.url?.host, "replicate.delivery")
        XCTAssertNil(records[6].request.value(forHTTPHeaderField: "Authorization"))
        for record in records where record.request.url?.host == "api.replicate.com" {
            XCTAssertEqual(record.request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")
        }
        let multipart = try XCTUnwrap(records[0].upload)
        XCTAssertTrue(multipart.contains("name=\"content\"; filename=\"input.png\""))
        XCTAssertTrue(multipart.contains("Content-Type: image/png"))
        let submission = try XCTUnwrap(records[2].request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: submission) as? [String: Any])
        let parameters = try XCTUnwrap(payload["input"] as? [String: Any])
        XCTAssertEqual(payload["version"] as? String, "\(ReplicateClient.model):\(ReplicateClient.version)")
        XCTAssertEqual(records[2].request.value(forHTTPHeaderField: "Cancel-After"), "10m")
        XCTAssertEqual(Set(parameters.keys), ["image", "scale", "face_enhance"])
        XCTAssertEqual(parameters["scale"] as? Int, 8)
        XCTAssertEqual(parameters["face_enhance"] as? Bool, false)
        XCTAssertEqual(parameters["image"] as? String, "https://api.replicate.com/v1/files/file1")
    }

    func testIncompleteFileAndPredictionResponsesThenSingleImageOutput() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([
            .init("POST /v1/files", 201, #"{"id":"file1"}"#),
            .init("POST /v1/predictions", 201, #"{"id":"job1","status":"processing","output":{"progress":0.5}}"#),
            .init("GET /v1/predictions/job1", 200, #"{"id":"job1","status":"succeeded","output":null}"#),
            .init("GET /v1/predictions/job1", 200, #"{"id":"job1","status":"succeeded","output":["https://replicate.delivery/result.png"]}"#),
            .init("GET /result.png", 200, "test-output"),
            .init("DELETE /v1/files/file1", 204)
        ])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport) { _ in }
        try await client.run(png: png, output: result, options: options) { _ in }

        let records = await transport.records
        let payload = try XCTUnwrap(records[1].request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let parameters = try XCTUnwrap(object["input"] as? [String: Any])
        XCTAssertEqual(parameters["image"] as? String, "https://api.replicate.com/v1/files/file1")
        XCTAssertEqual(try Data(contentsOf: result), Data("test-output".utf8))
    }

    func testMalformedUploadReportsTheUploadStage() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([.init("POST /v1/files", 201, #"{"unexpected":"response"}"#)])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport) { _ in }
        await expect(.replicateResponse(.uploading)) {
            try await client.run(png: png, output: result, options: self.options) { _ in }
        }
    }

    func testMissingOutputDoesNotCreateAnotherPrediction() async throws {
        let (_, png, result) = try files()
        let missing = #"{"id":"job1","status":"succeeded","output":null}"#
        let transport = ScriptTransport([
            .init("POST /v1/files", 201, upload),
            .init("POST /v1/predictions", 201, missing),
            .init("GET /v1/predictions/job1", 200, missing),
            .init("DELETE /v1/files/file1", 204)
        ])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport) { _ in }
        await expect(.predictionOutputUnavailable) {
            try await client.run(png: png, output: result, options: self.options) { _ in }
        }
        let pending = await transport.remaining
        XCTAssertEqual(pending, 0)
    }

    #if os(macOS)
    func testDeliveryAcceptsDecodedBytesWithDifferentContentLength() async throws {
        let (_, _, result) = try files()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = SessionTransport(session: session)
        let request = URLRequest(url: URL(string: "https://replicate.delivery/decoded-result")!)
        let response = try await transport.download(request, to: result, limit: 1_024)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: result), Data("decoded image response".utf8))
    }
    #endif

    func testAuthorizationFailureIsSanitized() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([.init("POST /v1/files", 401, "sensitive body")])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport)
        await expect(.unauthorized) { try await client.run(png: png, output: result, options: self.options) { _ in } }
        let count = await transport.records.count
        XCTAssertEqual(count, 1)
    }

    func testAmbiguousPredictionIsNeverAutomaticallyResubmitted() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([
            .init("POST /v1/files", 201, upload),
            .init("POST /v1/predictions", 503),
            .init("DELETE /v1/files/file1", 204)
        ])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport)
        await expect(.ambiguousSubmission) { try await client.run(png: png, output: result, options: self.options) { _ in } }
        let records = await transport.records
        XCTAssertEqual(records.filter { $0.request.url?.path == "/v1/predictions" }.count, 1)
    }

    func testThirdPartyOutputIsRejectedWithoutRequest() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([
            .init("POST /v1/files", 201, upload),
            .init("POST /v1/predictions", 201, success.replacingOccurrences(of: "replicate.delivery", with: "replicate.delivery.invalid")),
            .init("DELETE /v1/files/file1", 204)
        ])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport)
        await expect(.unsafeURL) { try await client.run(png: png, output: result, options: self.options) { _ in } }
        let requests = await transport.records.map(\.request)
        XCTAssertEqual(requests.map { $0.url?.host }, Array(repeating: "api.replicate.com", count: 3))
    }

    func testCancellationStopsKnownPredictionAndDeletesCloudInput() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([
            .init("POST /v1/files", 201, upload),
            .init("POST /v1/predictions", 201, processing),
            .init("POST /v1/predictions/job1/cancel", 200, #"{"id":"job1","status":"aborted","output":null}"#),
            .init("DELETE /v1/files/file1", 204)
        ])
        let started = expectation(description: "Prediction ID available")
        let client = try ReplicateClient(token: "unit-test-token", transport: transport)
        let options = self.options
        let task = Task {
            try await client.run(png: png, output: result, options: options) { stage in
                if stage == .processing { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancellation was expected")
        } catch is CancellationError {
            let pending = await transport.remaining
            XCTAssertEqual(pending, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
    }

    func testTimeoutCancelsKnownPrediction() async throws {
        let (_, png, result) = try files()
        let transport = ScriptTransport([
            .init("POST /v1/files", 201, upload),
            .init("POST /v1/predictions", 201, processing),
            .init("POST /v1/predictions/job1/cancel", 200, #"{"id":"job1","status":"canceled","output":null}"#),
            .init("DELETE /v1/files/file1", 204)
        ])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport, pollingTimeout: .zero)
        await expect(.timedOut) { try await client.run(png: png, output: result, options: self.options) { _ in } }
        let pending = await transport.remaining
        XCTAssertEqual(pending, 0)
    }

    func testRejectsOversizedUploadBeforeNetwork() async throws {
        let (_, png, result) = try files()
        let file = try FileHandle(forWritingTo: png)
        try file.truncate(atOffset: UInt64(ImageLimits.cloudBytes + 1))
        try file.close()
        let transport = ScriptTransport([])
        let client = try ReplicateClient(token: "unit-test-token", transport: transport)
        await expect(.inputTooLarge) { try await client.run(png: png, output: result, options: self.options) { _ in } }
        let requests = await transport.records
        XCTAssertTrue(requests.isEmpty)
    }

    func testURLSessionUsesInjectedProtocol() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = SessionTransport(session: session)
        var request = URLRequest(url: URL(string: "https://api.replicate.com/v1/predictions/job1")!)
        request.setValue("Bearer unit-test-token", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await transport.response(for: request, upload: nil)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Bearer unit-test-token")
    }

    private func files() throws -> (URL, URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("input.png")
        try Data("PNG bytes".utf8).write(to: png)
        return (folder, png, folder.appendingPathComponent("result.png"))
    }

    private func expect(_ expected: PixelLiftError, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? PixelLiftError, expected)
        }
    }
}

private final class SessionStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let delivery = url.path == "/decoded-result"
        let headers = delivery ? ["Content-Length": "35", "Content-Type": "image/png"] : nil
        let body = delivery ? "decoded image response" : (request.value(forHTTPHeaderField: "Authorization") ?? "")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor Trace<Value: Sendable> {
    private(set) var items: [Value] = []
    func add(_ item: Value) { items.append(item) }
}

private actor ScriptTransport: ReplicateTransport {
    struct Step {
        let route: String
        let status: Int
        let text: String
        let headers: [String: String]

        init(_ route: String, _ status: Int, _ text: String = "", headers: [String: String] = [:]) {
            self.route = route
            self.status = status
            self.text = text
            self.headers = headers
        }
    }

    struct Record: Sendable {
        let request: URLRequest
        let upload: String?
    }

    private var steps: [Step]
    private(set) var records: [Record] = []
    var remaining: Int { steps.count }

    init(_ steps: [Step]) { self.steps = steps }

    func response(for request: URLRequest, upload: URL?) async throws -> (Data, HTTPURLResponse) {
        try next(request, upload: upload)
    }

    func download(_ request: URLRequest, to file: URL, limit: Int) async throws -> HTTPURLResponse {
        XCTAssertEqual(limit, ImageLimits.resultBytes)
        let (bytes, response) = try next(request, upload: nil)
        if response.statusCode == 200 { try bytes.write(to: file) }
        return response
    }

    private func next(_ request: URLRequest, upload: URL?) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let route = "\(request.httpMethod ?? "GET") \(url.path)"
        let body = try upload.map { try String(contentsOf: $0, encoding: .utf8) }
        records.append(Record(request: request, upload: body))
        guard let step = steps.first else {
            XCTFail("Unexpected request: \(route)")
            throw PixelLiftError.invalidResponse
        }
        steps.removeFirst()
        XCTAssertEqual(route, step.route)
        return (Data(step.text.utf8), HTTPURLResponse(url: url, statusCode: step.status,
                httpVersion: "HTTP/1.1", headerFields: step.headers)!)
    }
}
