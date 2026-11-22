import AppKit
import PixelLiftCore
import SwiftUI

enum ProviderChoice: String, CaseIterable, Identifiable {
    case mock, replicate
    var id: String { rawValue }
    var label: String { self == .mock ? "Mock" : "Replicate" }
}

struct WorkspaceImage: Identifiable {
    let id = UUID()
    let url: URL
    let info: ImageInfo
    var result: RenderedResult? = nil
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var images: [WorkspaceImage] = []
    @Published var selectedID: UUID?
    @Published var message: UserMessage?
    @Published var scale: UpscaleScale = .four {
        didSet { UserDefaults.standard.set(scale.rawValue, forKey: "scale") }
    }
    @Published var provider: ProviderChoice = .mock {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") }
    }
    @Published private(set) var tokenSaved = false
    @Published var confirmingCloud = false
    @Published private(set) var stage: UpscaleStage?
    @Published var mode: UpscaleMode = .preserveFaces {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var exportFormat: ExportFormat = .png {
        didSet { UserDefaults.standard.set(exportFormat.rawValue, forKey: "exportFormat") }
    }
    @Published var jpegQuality = 0.92 {
        didSet { UserDefaults.standard.set(jpegQuality, forKey: "jpegQuality") }
    }
    @Published var settingsMessage: UserMessage?
    @Published private(set) var exportFolder: URL?
    @Published private(set) var saving = false
    @Published private(set) var processing = false

    var selected: WorkspaceImage? { images.first { $0.id == selectedID } }

    init() {
        provider = ProviderChoice(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .mock
        mode = UpscaleMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .preserveFaces
        exportFormat = ExportFormat(rawValue: UserDefaults.standard.string(forKey: "exportFormat") ?? "") ?? .png
        jpegQuality = UserDefaults.standard.object(forKey: "jpegQuality") as? Double ?? 0.92
        exportFolder = resolveExportFolder()
        tokenSaved = (try? ReplicateKeychain.read()) != nil
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
                let access = path.startAccessingSecurityScopedResource()
                defer { if access { path.stopAccessingSecurityScopedResource() } }
                let row = WorkspaceImage(url: path, info: try ImageFiles.inspect(path))
                images.append(row)
                if selectedID == nil { selectedID = row.id }
            } catch {
                message = UserMessage(title: "読み込みエラー", text: userText(error))
            }
        }
    }

    func saveToken(_ token: String) -> Bool {
        do {
            try ReplicateKeychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            tokenSaved = true
            return true
        } catch {
            settingsMessage = UserMessage(title: "APIキーの設定", text: userText(error))
            return false
        }
    }

    func removeToken() {
        do {
            try ReplicateKeychain.remove()
            tokenSaved = false
        } catch {
            settingsMessage = UserMessage(title: "APIキーの設定", text: userText(error))
        }
    }

    func chooseExportFolder() {
        _ = selectExportFolder()
    }

    func clearExportFolder() {
        UserDefaults.standard.removeObject(forKey: "exportBookmark")
        exportFolder = nil
    }

    func saveSelected() {
        guard let item = selected, let result = item.result, !saving,
              let folder = resolveExportFolder() ?? selectExportFolder() else { return }
        saving = true
        let format = exportFormat
        let quality = jpegQuality
        Task {
            defer { saving = false }
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    let access = folder.startAccessingSecurityScopedResource()
                    defer { if access { folder.stopAccessingSecurityScopedResource() } }
                    return try ImageFiles.export(result.url, into: folder, originalName: item.url.lastPathComponent,
                                                 scale: result.scale, format: format, quality: quality)
                }.value
                message = UserMessage(title: "保存完了", text: saved.lastPathComponent)
            } catch {
                message = UserMessage(title: "保存エラー", text: userText(error))
            }
        }
    }

    private func selectExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "選択")
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        do {
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "exportBookmark")
            exportFolder = folder
        } catch {
            settingsMessage = UserMessage(title: "保存先の設定", text: userText(error))
        }
        return folder
    }

    private func resolveExportFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: "exportBookmark") else { return nil }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            if let updated = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(updated, forKey: "exportBookmark")
            }
        }
        return folder
    }

    func start() {
        if provider == .replicate { confirmingCloud = true }
        else { process(provider: .mock) }
    }

    func confirmCloud() { process(provider: .replicate) }

    private func setStage(_ value: UpscaleStage) { stage = value }

    private func process(provider choice: ProviderChoice) {
        guard let selected, !processing else { return }
        let client: any CloudUpscaleProvider
        do {
            switch choice {
            case .mock: client = MockUpscaleProvider()
            case .replicate: client = try ReplicateUpscaleProvider(token: ReplicateKeychain.read() ?? "")
            }
        } catch {
            message = UserMessage(title: "処理エラー", text: userText(error))
            return
        }
        processing = true
        let input = selected.url
        let imageID = selected.id
        let info = selected.info
        let options = UpscaleOptions(scale: scale, mode: choice == .mock ? .standard : mode)
        Task {
            defer { processing = false; stage = nil }
            do {
                let multiplier = options.scale.rawValue
                try ImageLimits.check(width: info.width, height: info.height, scale: multiplier)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let output = folder.appendingPathComponent("result.png")
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let accessed = input.startAccessingSecurityScopedResource()
                        defer { if accessed { input.stopAccessingSecurityScopedResource() } }
                        try await client.upscale(input: input, output: output, options: options) { [weak self] stage in
                            await self?.setStage(stage)
                        }
                    }.value
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                do {
                    let outputInfo = try ImageFiles.inspect(output, limit: ImageLimits.resultBytes)
                    guard outputInfo.width == info.width * multiplier, outputInfo.height == info.height * multiplier else {
                        throw PixelLiftError.wrongOutputDimensions
                    }
                    if let index = images.firstIndex(where: { $0.id == imageID }) {
                        if let old = images[index].result {
                            try? FileManager.default.removeItem(at: old.url.deletingLastPathComponent())
                        }
                        images[index].result = RenderedResult(url: output, info: outputInfo, scale: options.scale, provider: client.name)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
            } catch {
                message = UserMessage(title: "処理エラー", text: userText(error))
            }
        }
    }
}
