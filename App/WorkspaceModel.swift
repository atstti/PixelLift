import AppKit
import PixelLiftCore
import SwiftUI

enum ProviderChoice: String, CaseIterable, Identifiable, Sendable {
    case mock, replicate
    var id: String { rawValue }
    var label: String { self == .mock ? "Mock" : "Replicate" }
    var modes: [UpscaleMode] { self == .mock ? MockUpscaleProvider().modes : ReplicateUpscaleProvider.availableModes }
}

enum RowStatus: Sendable {
    case ready, waiting, running(UpscaleStage), cancelling, canceled, completed, failed(PixelLiftError)

    var title: LocalizedStringKey {
        switch self {
        case .ready: return "未処理"
        case .waiting: return "処理待ち"
        case .running: return "処理中"
        case .cancelling: return "キャンセル処理中"
        case .canceled: return "キャンセル済み"
        case .completed: return "完了"
        case .failed: return "失敗"
        }
    }

    var canCancel: Bool {
        switch self {
        case .waiting, .running: return true
        default: return false
        }
    }

    var isEnqueued: Bool {
        if case .cancelling = self { return true }
        return canCancel
    }

    var canRetry: Bool {
        switch self {
        case .failed, .canceled: return true
        default: return false
        }
    }
}

struct BatchRequest: Sendable {
    let provider: ProviderChoice
    let options: UpscaleOptions
}

struct WorkspaceImage: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let info: ImageInfo
    var result: RenderedResult?
    var status: RowStatus = .ready
    var lastRequest: BatchRequest?
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var images: [WorkspaceImage] = []
    @Published var selectedID: UUID?
    @Published var message: UserMessage?
    @Published var settingsMessage: UserMessage?
    @Published var scale: UpscaleScale = .four {
        didSet { UserDefaults.standard.set(scale.rawValue, forKey: "scale") }
    }
    @Published var provider: ProviderChoice = .mock {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") }
    }
    @Published var mode: UpscaleMode = .preserveFaces {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var exportFormat: ExportFormat = .png {
        didSet { UserDefaults.standard.set(exportFormat.rawValue, forKey: "exportFormat") }
    }
    @Published var jpegQuality = 0.92 {
        didSet { UserDefaults.standard.set(jpegQuality, forKey: "jpegQuality") }
    }
    @Published var concurrentJobs = 1 {
        didSet {
            UserDefaults.standard.set(concurrentJobs, forKey: "concurrentJobs")
            queue.setLimit(concurrentJobs)
        }
    }
    @Published private(set) var tokenSaved = false
    @Published private(set) var exportFolder: URL?
    @Published private(set) var saving = false
    @Published private(set) var maintainingCache = false
    @Published private(set) var cacheBytes: Int?
    @Published private(set) var bundleBytes: Int?
    @Published private(set) var cloudRequests = 0
    @Published var confirmingCloud = false

    private struct Submission {
        let ids: [UUID]
        let request: BatchRequest
    }

    private let queue = JobQueue<RenderedResult>()
    private let cacheDirectory: CacheDirectory?
    private let cache: ResultCache?
    private let cacheError: PixelLiftError?
    private var pendingConsent: Submission?
    private var quitObserver: NSObjectProtocol?

    var selected: WorkspaceImage? { images.first { $0.id == selectedID } }
    var readyCount: Int { images.filter { if case .ready = $0.status { return true }; return false }.count }
    var runningCount: Int { images.filter { switch $0.status { case .running, .cancelling: return true; default: return false } }.count }
    var waitingCount: Int { images.filter { if case .waiting = $0.status { return true }; return false }.count }
    var completedCount: Int { images.filter { if case .completed = $0.status { return true }; return false }.count }
    var failedCount: Int { images.filter { if case .failed = $0.status { return true }; return false }.count }
    var resultCount: Int { images.filter { $0.result != nil }.count }
    var busy: Bool { images.contains { $0.status.isEnqueued } }
    var canSave: Bool { !busy && !saving && !maintainingCache }
    var canClearCache: Bool { canSave && cache != nil }
    var canStart: Bool { readyCount > 0 && !saving && !maintainingCache }
    var consentCount: Int { pendingConsent?.ids.count ?? 0 }

    init() {
        do {
            let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            let directory = try CacheDirectory(base: base.appendingPathComponent("app.pixelliftai.macos", isDirectory: true))
            cacheDirectory = directory
            cache = ResultCache(directory: directory)
            cacheError = nil
        } catch {
            cacheDirectory = nil
            cache = nil
            cacheError = error as? PixelLiftError ?? .fileOperation
        }
        let preferences = UserDefaults.standard
        provider = ProviderChoice(rawValue: preferences.string(forKey: "provider") ?? "") ?? .mock
        scale = UpscaleScale(rawValue: preferences.integer(forKey: "scale")) ?? .four
        mode = UpscaleMode(rawValue: preferences.string(forKey: "mode") ?? "") ?? .preserveFaces
        exportFormat = ExportFormat(rawValue: preferences.string(forKey: "exportFormat") ?? "") ?? .png
        jpegQuality = min(1, max(0.05, preferences.object(forKey: "jpegQuality") as? Double ?? 0.92))
        concurrentJobs = min(2, max(1, preferences.integer(forKey: "concurrentJobs")))

        if let directory = cacheDirectory {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                  object: nil, queue: .main) { _ in
                directory.discardSession()
            }
        }
        tokenSaved = (try? ReplicateKeychain.read()) != nil
        exportFolder = resolveExportFolder()
        queue.setLimit(concurrentJobs)
        queue.onUpdate = { [weak self] id, update in self?.receive(id, update) }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    func openImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageFiles.types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addImages(panel.urls) }
    }

    func addImages(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls where url.isFileURL {
            guard !images.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let row = WorkspaceImage(url: url, info: try ImageFiles.inspect(url))
                images.append(row)
                if selectedID == nil { selectedID = row.id }
            } catch {
                failures.append("\(url.lastPathComponent)\n\(userText(error))")
            }
        }
        if !failures.isEmpty {
            message = UserMessage(title: "読み込みエラー", text: summary(failures))
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

    func chooseExportFolder() { _ = selectExportFolder() }

    func clearExportFolder() {
        UserDefaults.standard.removeObject(forKey: "exportBookmark")
        exportFolder = nil
    }

    func saveSelected() {
        if let selected { save([selected]) }
    }

    func saveAll() { save(images) }

    func start() {
        let ids = images.compactMap { item -> UUID? in
            if case .ready = item.status { return item.id }
            return nil
        }
        request(ids: ids, settings: currentRequest)
    }

    func reprocess(_ id: UUID) { request(ids: [id], settings: currentRequest) }

    func retry(_ id: UUID) {
        guard let previous = images.first(where: { $0.id == id })?.lastRequest else { return }
        request(ids: [id], settings: previous)
    }

    func cancel(_ id: UUID) { queue.cancel(id) }
    func cancelAll() { queue.cancelAll() }

    func cancelConsent() { pendingConsent = nil }

    func confirmCloud() {
        guard let submission = pendingConsent else { return }
        pendingConsent = nil
        enqueue(submission)
    }

    func remove(_ id: UUID) {
        guard let item = images.first(where: { $0.id == id }), !item.status.isEnqueued,
              !saving, !maintainingCache else { return }
        if let result = item.result, let cache {
            maintainingCache = true
            Task {
                defer { maintainingCache = false }
                do {
                    try await cache.remove(result.ticket)
                    removeRow(id)
                    await refreshCacheUsage()
                } catch {
                    message = UserMessage(title: "キャッシュの削除", text: userText(error))
                }
            }
        } else {
            removeRow(id)
        }
    }

    func clearCache() {
        guard canSave, let cache else { return }
        maintainingCache = true
        Task {
            defer { maintainingCache = false }
            let remaining = await cache.clear()
            for index in images.indices {
                if let result = images[index].result, !remaining.contains(result.ticket) {
                    images[index].result = nil
                    images[index].status = .ready
                }
            }
            if !remaining.isEmpty {
                settingsMessage = UserMessage(title: "キャッシュの削除", text: PixelLiftError.fileOperation.userText)
            }
            await refreshCacheUsage()
        }
    }

    func refreshCacheUsage() async {
        if let cache { cacheBytes = try? await cache.sizeOnDisk() }
        if bundleBytes == nil {
            let bundle = Bundle.main.bundleURL
            bundleBytes = await Task.detached(priority: .utility) {
                Self.allocatedBytes(at: bundle)
            }.value
        }
    }

    private var currentRequest: BatchRequest {
        BatchRequest(provider: provider, options: UpscaleOptions(scale: scale,
                     mode: provider.modes.contains(mode) ? mode : (provider.modes.first ?? .standard)))
    }

    private func request(ids: [UUID], settings: BatchRequest) {
        guard !ids.isEmpty, !saving, !maintainingCache else { return }
        let submission = Submission(ids: ids, request: settings)
        if settings.provider == .replicate {
            guard tokenSaved else {
                message = UserMessage(title: "APIキーの設定", text: PixelLiftError.missingToken.userText)
                return
            }
            pendingConsent = submission
            confirmingCloud = true
        } else {
            enqueue(submission)
        }
    }

    private func enqueue(_ submission: Submission) {
        guard !saving, !maintainingCache else { return }
        guard let cache else {
            message = UserMessage(title: "作業領域を開けません", text: (cacheError ?? .fileOperation).userText)
            return
        }
        let client: any CloudUpscaleProvider
        do {
            switch submission.request.provider {
            case .mock: client = MockUpscaleProvider()
            case .replicate: client = try ReplicateUpscaleProvider(token: ReplicateKeychain.read() ?? "")
            }
        } catch {
            message = UserMessage(title: "処理エラー", text: userText(error))
            return
        }
        let jobs: [UpscaleJob<RenderedResult>] = submission.ids.compactMap { id in
            guard let index = images.firstIndex(where: { $0.id == id }), !images[index].status.isEnqueued else { return nil }
            images[index].lastRequest = submission.request
            let item = images[index]
            let options = submission.request.options
            return UpscaleJob(id: id) { progress in
                try await Self.process(item, options: options, using: client, cache: cache, progress: progress)
            }
        }
        queue.enqueue(jobs)
    }

    private nonisolated static func process(_ item: WorkspaceImage, options: UpscaleOptions,
                         using client: any CloudUpscaleProvider, cache: ResultCache,
                         progress: @escaping UpscaleJob<RenderedResult>.Progress) async throws -> RenderedResult {
        let access = item.url.startAccessingSecurityScopedResource()
        defer { if access { item.url.stopAccessingSecurityScopedResource() } }
        let input = try ImageFiles.inspect(item.url, limit: client.sendsImages ? ImageLimits.cloudBytes : ImageLimits.importBytes)
        let scale = options.scale.rawValue
        try ImageLimits.check(width: input.width, height: input.height, scale: scale)
        guard input == item.info else { throw PixelLiftError.sourceChanged }
        try Task.checkCancellation()
        // The upload scratch (two input copies at most) is removed before downloading the result.
        let ticket = try await cache.reserve(bytes: ImageLimits.resultBytes)
        do {
            try await client.upscale(input: item.url, output: ticket.output, options: options, progress: progress)
            try Task.checkCancellation()
            let info = try ImageFiles.inspect(ticket.output, limit: ImageLimits.resultBytes)
            guard info.width == input.width * scale, info.height == input.height * scale else {
                throw PixelLiftError.wrongOutputDimensions
            }
            _ = try ImageFiles.preview(ticket.output, maxSide: 32)
            try await cache.commit(ticket)
            return RenderedResult(ticket: ticket, info: info, scale: options.scale, provider: client.name)
        } catch {
            try? await cache.remove(ticket)
            throw error
        }
    }

    private func receive(_ id: UUID, _ update: JobUpdate<RenderedResult>) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        switch update {
        case .waiting: images[index].status = .waiting
        case .running(let stage):
            if stage == .starting { cloudRequests += 1 }
            images[index].status = .running(stage)
        case .cancelling: images[index].status = .cancelling
        case .canceled: images[index].status = .canceled
        case .completed(let result):
            if let old = images[index].result, let cache {
                Task { try? await cache.remove(old.ticket) }
            }
            images[index].result = result
            images[index].status = .completed
        case .failed(let error): images[index].status = .failed(error)
        }
    }

    private func save(_ rows: [WorkspaceImage]) {
        guard canSave else { return }
        let items = rows.filter { $0.result != nil }
        guard !items.isEmpty, let folder = resolveExportFolder() ?? selectExportFolder() else { return }
        saving = true
        let format = exportFormat
        let quality = jpegQuality
        Task {
            defer { saving = false }
            let report = await Task.detached(priority: .userInitiated) {
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                var saved: [String] = []
                var failures: [(String, PixelLiftError)] = []
                for item in items {
                    guard let result = item.result else { continue }
                    do {
                        let file = try ImageFiles.export(result.url, into: folder, originalName: item.url.lastPathComponent,
                                                        scale: result.scale, format: format, quality: quality)
                        saved.append(file.lastPathComponent)
                    } catch {
                        failures.append((item.url.lastPathComponent, error as? PixelLiftError ?? .fileOperation))
                    }
                }
                return (saved, failures)
            }.value
            let details = report.0 + report.1.map { "\($0.0)\n\($0.1.userText)" }
            let count = String(localized: "\(report.0.count)件を保存、\(report.1.count)件が失敗しました。")
            message = UserMessage(title: report.1.isEmpty ? "保存完了" : "保存結果",
                                  text: "\(count)\n\n\(summary(details))")
        }
    }

    private func removeRow(_ id: UUID) {
        images.removeAll { $0.id == id }
        if selectedID == id { selectedID = images.first?.id }
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
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else {
            clearExportFolder()
            return nil
        }
        if stale {
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            if let updated = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(updated, forKey: "exportBookmark")
            }
        }
        return folder
    }

    private func summary(_ lines: [String]) -> String {
        let visible = lines.prefix(6).joined(separator: "\n\n")
        if lines.count <= 6 { return visible }
        return visible + "\n\n" + String(localized: "ほか\(lines.count - 6)件")
    }

    private nonisolated static func allocatedBytes(at directory: URL) -> Int? {
        guard let files = FileManager.default.enumerator(at: directory,
                                                         includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else { return nil }
        var bytes = 0
        for case let file as URL in files {
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
               values.isRegularFile == true {
                bytes += values.totalFileAllocatedSize ?? values.fileSize ?? 0
            }
        }
        return bytes
    }
}
