import AppKit
import PixelLiftCore
import SwiftUI

struct WorkspaceImage: Identifiable {
    let id = UUID()
    let url: URL
    let info: ImageInfo
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var images: [WorkspaceImage] = []
    @Published var selectedID: UUID?
    @Published var message: UserMessage?
    @Published var scale: UpscaleScale = .four {
        didSet { UserDefaults.standard.set(scale.rawValue, forKey: "scale") }
    }
    @Published private(set) var mockResult: URL?
    @Published private(set) var processing = false
    private var mockFolder: URL?

    var selected: WorkspaceImage? { images.first { $0.id == selectedID } }

    init() {
        scale = UpscaleScale(rawValue: UserDefaults.standard.integer(forKey: "scale")) ?? .four
    }

    func openImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageFiles.types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addImages(panel.urls) }
    }

    func addImages(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL
            guard !images.contains(where: { $0.url == path }) else { continue }
            do {
                let row = WorkspaceImage(url: path, info: try ImageFiles.inspect(path))
                images.append(row)
                if selectedID == nil { selectedID = row.id }
            } catch {
                message = UserMessage(title: "読み込みエラー", text: userText(error))
            }
        }
    }

    func start() {
        guard let selected, !processing else { return }
        processing = true
        let input = selected.url
        let options = UpscaleOptions(scale: scale, mode: .standard)
        Task {
            defer { processing = false }
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let output = folder.appendingPathComponent("result.png")
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try await MockUpscaleProvider().upscale(input: input, output: output, options: options) { _ in }
                    }.value
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                if let mockFolder { try? FileManager.default.removeItem(at: mockFolder) }
                mockFolder = folder
                mockResult = output
            } catch {
                message = UserMessage(title: "処理エラー", text: userText(error))
            }
        }
    }
}
