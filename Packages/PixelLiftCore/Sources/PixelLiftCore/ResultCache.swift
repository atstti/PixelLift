import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public final class CacheDirectory: @unchecked Sendable {
    public let url: URL
    private let lock: FileHandle

    public init(base: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = base.appendingPathComponent("lock")
        let fd = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { throw PixelLiftError.fileOperation }
        let lock = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PixelLiftError.cacheBusy }
        let directory = base.appendingPathComponent("session", isDirectory: true)
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.url = directory
        self.lock = lock
    }

    public func discardSession() { try? FileManager.default.removeItem(at: url) }

    deinit {
        discardSession()
        // Keep the process lock until all files belonging to this session have been removed.
        try? lock.close()
    }
}

public actor ResultCache {
    public static let limit = 512 * 1_024 * 1_024

    public struct Ticket: Hashable, Sendable {
        fileprivate let id: UUID
        public let folder: URL
        public var output: URL { folder.appendingPathComponent("result") }
    }

    private struct Entry {
        let folder: URL
        var budget: Int
        var finished: Bool
    }

    private let directory: CacheDirectory
    private let limit: Int
    private var entries: [UUID: Entry] = [:]

    public init(directory: CacheDirectory, limit: Int = ResultCache.limit) {
        self.directory = directory
        self.limit = limit
    }

    public func reserve(bytes: Int) throws -> Ticket {
        let allocated = entries.values.reduce(0) { $0 + $1.budget }
        guard bytes > 0, bytes <= limit - allocated else { throw PixelLiftError.cacheFull }
        let id = UUID()
        let folder = directory.url.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        entries[id] = Entry(folder: folder, budget: bytes, finished: false)
        return Ticket(id: id, folder: folder)
    }

    public func commit(_ ticket: Ticket) throws {
        guard var entry = entries[ticket.id], !entry.finished else { throw PixelLiftError.fileOperation }
        let contents = try FileManager.default.contentsOfDirectory(at: ticket.folder,
                                                                  includingPropertiesForKeys: [.fileSizeKey])
        guard contents.map(\.lastPathComponent) == [ticket.output.lastPathComponent], let bytes = try ticket.output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              bytes > 0, bytes <= entry.budget, bytes <= ImageLimits.resultBytes else {
            throw PixelLiftError.outputTooLarge
        }
        entry.finished = true
        entry.budget = bytes
        entries[ticket.id] = entry
    }

    public func remove(_ ticket: Ticket) throws {
        guard let entry = entries[ticket.id] else { return }
        do {
            try FileManager.default.removeItem(at: entry.folder)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The system may clear the app cache directory under storage pressure.
        }
        entries.removeValue(forKey: ticket.id)
    }

    public func clear() -> Set<Ticket> {
        let tickets = entries.map { Ticket(id: $0.key, folder: $0.value.folder) }
        for ticket in tickets { try? remove(ticket) }
        return Set(entries.map { Ticket(id: $0.key, folder: $0.value.folder) })
    }

    public func usage() -> Int {
        entries.values.filter(\.finished).reduce(0) { $0 + $1.budget }
    }

    public func sizeOnDisk() throws -> Int {
        guard let files = FileManager.default.enumerator(at: directory.url,
                                                         includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else {
            throw PixelLiftError.fileOperation
        }
        var bytes = 0
        for case let file as URL in files {
            // A running job can remove a scratch file during enumeration.
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
               values.isRegularFile == true {
                bytes += values.totalFileAllocatedSize ?? values.fileSize ?? 0
            }
        }
        return bytes
    }
}
