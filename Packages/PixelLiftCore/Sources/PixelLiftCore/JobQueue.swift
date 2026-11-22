import Foundation

public enum JobUpdate<Output: Sendable>: Sendable {
    case waiting, running(UpscaleStage), cancelling, canceled, completed(Output), failed(PixelLiftError)
}

public struct UpscaleJob<Output: Sendable>: Sendable {
    public typealias Progress = @Sendable (UpscaleStage) async -> Void
    public let id: UUID
    fileprivate let operation: @Sendable (@escaping Progress) async throws -> Output

    public init(id: UUID, operation: @escaping @Sendable (@escaping Progress) async throws -> Output) {
        self.id = id
        self.operation = operation
    }
}

@MainActor
public final class JobQueue<Output: Sendable> {
    public var onUpdate: ((UUID, JobUpdate<Output>) -> Void)?
    public private(set) var limit = 1
    public var count: Int { pending.count + running.count }
    private var pending: [UpscaleJob<Output>] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var cancelling: Set<UUID> = []

    public init() {}

    public func setLimit(_ limit: Int) {
        self.limit = min(2, max(1, limit))
        startPending()
    }

    public func enqueue(_ jobs: [UpscaleJob<Output>]) {
        for job in jobs {
            guard running[job.id] == nil, !pending.contains(where: { $0.id == job.id }) else { continue }
            pending.append(job)
            onUpdate?(job.id, .waiting)
        }
        startPending()
    }

    public func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            onUpdate?(id, .canceled)
        } else if let task = running[id], cancelling.insert(id).inserted {
            task.cancel()
            onUpdate?(id, .cancelling)
        }
    }

    public func cancelAll() {
        let pendingIDs = pending.map(\.id)
        let activeIDs = Array(running.keys)
        for id in pendingIDs + activeIDs { cancel(id) }
    }

    private func startPending() {
        while running.count < limit, !pending.isEmpty {
            let job = pending.removeFirst()
            let id = job.id
            running[id] = Task.detached(priority: .userInitiated) { [weak self] in
                let update: JobUpdate<Output>
                do {
                    let output = try await job.operation { [weak self] stage in
                        await self?.report(stage, id: id)
                    }
                    update = .completed(output)
                } catch is CancellationError {
                    update = .canceled
                } catch {
                    update = .failed(error as? PixelLiftError ?? .fileOperation)
                }
                await self?.finish(id, update: update)
            }
            onUpdate?(id, .running(.preparing))
        }
    }

    private func report(_ stage: UpscaleStage, id: UUID) {
        if running[id] != nil, !cancelling.contains(id) { onUpdate?(id, .running(stage)) }
    }

    private func finish(_ id: UUID, update: JobUpdate<Output>) {
        running.removeValue(forKey: id)
        cancelling.remove(id)
        onUpdate?(id, update)
        startPending()
    }
}
