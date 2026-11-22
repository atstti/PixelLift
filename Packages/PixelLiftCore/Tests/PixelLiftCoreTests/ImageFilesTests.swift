#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PixelLiftCore

final class ImageFilesTests: XCTestCase {
    func testPNGJPEGAndTIFFInputWithFileSignatureDetection() throws {
        let folder = try makeFolder()
        for format in [UTType.png, .jpeg, .tiff] {
            let file = folder.appendingPathComponent("\(format.identifier).data")
            try fixture(file, type: format)
            let info = try ImageFiles.inspect(file)
            XCTAssertEqual(info.type, format.identifier)
            XCTAssertEqual(info.width, 8)
            XCTAssertEqual(info.height, 5)
            XCTAssertGreaterThan(info.bytes, 0)
            XCTAssertEqual(info.frameCount, 1)
        }
        let bad = folder.appendingPathComponent("bad.png")
        try Data("invalid image".utf8).write(to: bad)
        XCTAssertThrowsError(try ImageFiles.inspect(bad))
    }

    func testWebPInputAndCloudPreparation() throws {
        let folder = try makeFolder()
        let webp = folder.appendingPathComponent("input.webp")
        let png = folder.appendingPathComponent("upload.png")
        let data = try XCTUnwrap(Data(base64Encoded: "UklGRiQAAABXRUJQVlA4TBcAAAAvBwABAA/wOu5TfF3Fbf6jBff/j+h/eAA="))
        try data.write(to: webp)
        let input = try ImageFiles.inspect(webp)
        XCTAssertEqual(input.type, UTType.webP.identifier)
        try ImageFiles.prepareUpload(webp, to: png)
        let prepared = try ImageFiles.inspect(png)
        XCTAssertEqual(prepared.type, UTType.png.identifier)
        XCTAssertEqual(prepared.width, input.width)
        XCTAssertEqual(prepared.height, input.height)
    }

    func testEXIFOrientationsAndMetadataRemoval() throws {
        let folder = try makeFolder()
        for rotation in 1...8 {
            let jpg = folder.appendingPathComponent("orientation-\(rotation).jpg")
            let png = folder.appendingPathComponent("normalized-\(rotation).png")
            try fixture(jpg, type: .jpeg, orientation: rotation)
            let info = try ImageFiles.inspect(jpg)
            let size = rotation >= 5 ? (5, 8) : (8, 5)
            XCTAssertEqual(info.width, size.0)
            XCTAssertEqual(info.height, size.1)
            let image = try ImageFiles.pixels(jpg, info: info)
            XCTAssertEqual(image.width, size.0)
            XCTAssertEqual(image.height, size.1)
            try ImageFiles.prepareUpload(jpg, to: png)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            XCTAssertNil(props?[kCGImagePropertyGPSDictionary])
        }
    }

    func testMockAndSaveAllFormatsWithoutOverwriting() async throws {
        let folder = try makeFolder()
        let original = folder.appendingPathComponent("photo.png")
        let result = folder.appendingPathComponent("result")
        try fixture(original, type: .png)
        let originalBytes = try Data(contentsOf: original)
        let sentinel = folder.appendingPathComponent("photo_4x.png")
        try Data([42]).write(to: sentinel)
        try await MockUpscaleProvider().upscale(input: original, output: result,
                   options: UpscaleOptions(scale: .four, mode: .standard)) { _ in }
        let rendered = try ImageFiles.inspect(result)
        XCTAssertEqual(rendered.width, 32)
        XCTAssertEqual(rendered.height, 20)
        for format in ExportFormat.allCases {
            let file = try ImageFiles.export(result, into: folder, originalName: original.lastPathComponent,
                                             scale: .four, format: format, quality: 0.71)
            let output = try ImageFiles.inspect(file)
            XCTAssertEqual(output.type, format.type.identifier)
            XCTAssertEqual(output.width, rendered.width)
            XCTAssertEqual(output.height, rendered.height)
            XCTAssertNoThrow(try ImageFiles.pixels(file, info: output))
            let expected = format == .png ? "photo_4x_2.png" : "photo_4x.\(format.fileExtension)"
            XCTAssertEqual(file.lastPathComponent, expected)
        }
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([42]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains {
            $0.hasPrefix(".pixellift-")
        })
    }

    func testLargePreviewAndResizeMemory() throws {
        let folder = try makeFolder()
        let photo = folder.appendingPathComponent("large.png")
        let result = folder.appendingPathComponent("result")
        try fixture(photo, type: .png, width: 3000, height: 2000)
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric()], options: options) {
            do {
                let preview = try ImageFiles.preview(photo, maxSide: 1200)
                XCTAssertEqual(preview.width, 1200)
                XCTAssertEqual(preview.height, 800)
                try ImageFiles.interpolate(photo, to: result, scale: .two)
                let encoded = try ImageFiles.inspect(result)
                XCTAssertEqual(encoded.width, 6000)
                XCTAssertEqual(encoded.height, 4000)
            } catch {
                XCTFail("Large image pipeline failed: \(error)")
            }
        }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func fixture(_ url: URL, type: UTType, width: Int = 8, height: Int = 5, orientation: Int = 1) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.1, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
#endif
