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
    @Published private(set) var mockResult: URL?
    @Published private(set) var processing = false
    private var mockFolder: URL?

    var selected: WorkspaceImage? { images.first { $0.id == selectedID } }

    init() {
        provider = ProviderChoice(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .mock
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
            message = UserMessage(title: "APIキーの設定", text: userText(error))
            return false
        }
    }

    func removeToken() {
        do {
            try ReplicateKeychain.remove()
            tokenSaved = false
        } catch {
            message = UserMessage(title: "APIキーの設定", text: userText(error))
        }
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
        let options = UpscaleOptions(scale: scale, mode: .standard)
        Task {
            defer { processing = false; stage = nil }
            do {
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
                if let mockFolder { try? FileManager.default.removeItem(at: mockFolder) }
                mockFolder = folder
                mockResult = output
            } catch {
                message = UserMessage(title: "処理エラー", text: userText(error))
            }
        }
    }
}
