import Foundation

public enum UpscaleScale: Int, CaseIterable, Identifiable, Sendable {
    case two = 2, four = 4, eight = 8
    public var id: Int { rawValue }
}

public enum UpscaleMode: String, CaseIterable, Identifiable, Sendable {
    case standard, preserveFaces, enhanceFaces
    public var id: String { rawValue }
    public var faceEnhancement: Bool { self == .enhanceFaces }
}

public struct UpscaleOptions: Sendable {
    public let scale: UpscaleScale
    public let mode: UpscaleMode

    public init(scale: UpscaleScale, mode: UpscaleMode) {
        self.scale = scale
        self.mode = mode
    }
}

public enum UpscaleStage: String, Equatable, Sendable {
    case preparing, uploading, starting, processing, downloading
}

public protocol CloudUpscaleProvider: Sendable {
    var name: String { get }
    var sendsImages: Bool { get }
    var modes: [UpscaleMode] { get }
    func upscale(
        input: URL,
        output: URL,
        options: UpscaleOptions,
        progress: @escaping @Sendable (UpscaleStage) async -> Void
    ) async throws
}

public enum ReplicateUploadProblem: Equatable, Sendable {
    case empty, tooLarge, missingID, invalidID, html, unreadable
}

public enum PixelLiftError: Error, Equatable, Sendable {
    case invalidImage, sourceChanged, dimensionsTooLarge, inputTooLarge, outputTooLarge, encodingFailed
    case cacheFull, cacheBusy, missingToken, invalidToken, invalidResponse, unsafeURL
    case replicateResponse(UpscaleStage), predictionOutputUnavailable
    case uploadResponse(status: Int, bytes: Int, problem: ReplicateUploadProblem)
    case unauthorized, rateLimited, timedOut, connection, ambiguousSubmission
    case http(Int), predictionFailed, predictionCanceled, cloudCancellationUnconfirmed
    case wrongOutputDimensions, fileOperation
}

public enum ImageLimits {
    public static let importBytes = 100 * 1_024 * 1_024
    public static let cloudBytes = 24 * 1_024 * 1_024
    public static let resultBytes = 128 * 1_024 * 1_024
    public static let maxPixels = 32_000_000
    public static let maxSide = 16_384

    public static func check(width: Int, height: Int, scale: Int = 1) throws {
        guard scale > 0, width > 0, height > 0, width <= maxSide / scale,
              height <= maxSide / scale, width <= maxPixels / scale / scale / height else {
            throw PixelLiftError.dimensionsTooLarge
        }
    }
}
