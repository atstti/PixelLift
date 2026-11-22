#if os(macOS)
import Foundation

public struct ReplicateUpscaleProvider: CloudUpscaleProvider {
    public let name = "Replicate"
    public let sendsImages = true
    public static let availableModes: [UpscaleMode] = [.preserveFaces, .enhanceFaces]
    public var modes: [UpscaleMode] { Self.availableModes }
    private let client: ReplicateClient

    public init(token: String) throws {
        client = try ReplicateClient(token: token)
    }

    public func upscale(input: URL, output: URL, options: UpscaleOptions,
                        progress: @escaping @Sendable (UpscaleStage) async -> Void) async throws {
        await progress(.preparing)
        let prepared = output.deletingLastPathComponent().appendingPathComponent("input.png")
        defer { try? FileManager.default.removeItem(at: prepared) }
        try Task.checkCancellation()
        try ImageFiles.prepareUpload(input, to: prepared)
        try await client.run(png: prepared, output: output, options: options, progress: progress)
    }
}
#endif
