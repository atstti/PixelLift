#if os(macOS)
import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bytes: Int
    public let type: String
    public let frameCount: Int
}

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, tiff
    public var id: String { rawValue }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }
}

public enum ImageFiles {
    public static let types: [UTType] = [.png, .jpeg, .tiff, .webP]
    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func inspect(_ url: URL, limit: Int = ImageLimits.importBytes) throws -> ImageInfo {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else {
            throw PixelLiftError.invalidImage
        }
        guard bytes <= limit else { throw PixelLiftError.inputTooLarge }
        let source = try imageSource(url)
        guard let type = CGImageSourceGetType(source) as String?,
              types.contains(where: { $0.identifier == type }),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int else {
            throw PixelLiftError.invalidImage
        }
        try ImageLimits.check(width: width, height: height)
        let rotated = (5...8).contains(metadata[kCGImagePropertyOrientation] as? Int ?? 1)
        return ImageInfo(width: rotated ? height : width, height: rotated ? width : height,
                         bytes: bytes, type: type, frameCount: CGImageSourceGetCount(source))
    }

    public static func preview(_ url: URL, maxSide: Int) throws -> CGImage {
        let source = try imageSource(url)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw PixelLiftError.invalidImage
        }
        return image
    }

    public static func pixels(_ url: URL, info: ImageInfo) throws -> CGImage {
        // ImageIO applies all eight EXIF orientations and keeps the full pixel dimensions.
        let image = try preview(url, maxSide: max(info.width, info.height))
        guard image.width == info.width, image.height == info.height else {
            throw PixelLiftError.invalidImage
        }
        return image
    }

    public static func prepareUpload(_ input: URL, to output: URL) throws {
        try autoreleasepool {
            let info = try inspect(input, limit: ImageLimits.cloudBytes)
            let image = try pixels(input, info: info)
            try write(image, to: output, format: .png)
            _ = try inspect(output, limit: ImageLimits.cloudBytes)
        }
    }

    public static func interpolate(_ input: URL, to output: URL, scale: UpscaleScale) throws {
        try autoreleasepool {
            let info = try inspect(input)
            try ImageLimits.check(width: info.width, height: info.height, scale: scale.rawValue)
            let image = try pixels(input, info: info)
            let scaled = CIImage(cgImage: image).applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: Double(scale.rawValue)
            ])
            let bounds = CGRect(x: 0, y: 0, width: info.width * scale.rawValue, height: info.height * scale.rawValue)
            guard let result = context.createCGImage(scaled, from: bounds) else {
                throw PixelLiftError.encodingFailed
            }
            try write(result, to: output, format: .png)
        }
    }

    public static func export(_ source: URL, into folder: URL, originalName: String,
                              scale: UpscaleScale, format: ExportFormat, quality: Double) throws -> URL {
        try autoreleasepool {
            let tmp = folder.appendingPathComponent(".pixellift-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let info = try inspect(source, limit: ImageLimits.resultBytes)
            let image = try pixels(source, info: info)
            try write(image, to: tmp, format: format, quality: quality)
            let originalStem = (originalName as NSString).deletingPathExtension
            var stem = ""
            for scalar in originalStem.unicodeScalars {
                if stem.utf8.count + String(scalar).utf8.count > 210 { break }
                stem.unicodeScalars.append(scalar)
            }
            if stem.isEmpty { stem = "image" }
            for index in 1...10_000 {
                let suffix = index == 1 ? "" : "_\(index)"
                let filename = "\(stem)_\(scale.rawValue)x\(suffix).\(format.fileExtension)"
                let destination = folder.appendingPathComponent(filename)
                do {
                    // Same-directory rename without replacement is supported on APFS and external volumes.
                    let status = tmp.withUnsafeFileSystemRepresentation { from in
                        destination.withUnsafeFileSystemRepresentation { to in
                            renamex_np(from!, to!, UInt32(RENAME_EXCL))
                        }
                    }
                    if status == 0 { return destination }
                    if errno != EEXIST { throw PixelLiftError.fileOperation }
                } catch {
                    throw error
                }
            }
            throw PixelLiftError.fileOperation
        }
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw PixelLiftError.invalidImage
        }
        return source
    }

    private static func write(_ image: CGImage, to url: URL,
                              format: ExportFormat, quality: Double = 0.92) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw PixelLiftError.encodingFailed
        }
        var options: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
            options[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1)
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PixelLiftError.encodingFailed }
    }
}

public struct MockUpscaleProvider: CloudUpscaleProvider {
    public let name = "Mock"
    public let sendsImages = false
    public let modes: [UpscaleMode] = [.standard]
    public init() {}

    public func upscale(input: URL, output: URL, options: UpscaleOptions,
                        progress: @escaping @Sendable (UpscaleStage) async -> Void) async throws {
        await progress(.processing)
        try await Task.sleep(for: .milliseconds(350))
        try ImageFiles.interpolate(input, to: output, scale: options.scale)
        try Task.checkCancellation()
    }
}
#endif
