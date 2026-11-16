public import Foundation
import OrganizerPosix

public struct ArchiveRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var fileName: String
    public var originalName: String
    public var kind: String
    public var projectTag: String
    public var modifiedAt: String
    public var platform: String
    public var publishStatus: String
    public var version: String
    public var path: String
    public var contentClass: String
    public var publishedAt: String
    public var bytes: Int64
    public var reason: String

    public init(
        id: String,
        fileName: String,
        originalName: String,
        kind: String,
        projectTag: String,
        modifiedAt: String,
        platform: String,
        publishStatus: String,
        version: String,
        path: String,
        contentClass: String,
        publishedAt: String,
        bytes: Int64,
        reason: String
    ) {
        self.id = id
        self.fileName = fileName
        self.originalName = originalName
        self.kind = kind
        self.projectTag = projectTag
        self.modifiedAt = modifiedAt
        self.platform = platform
        self.publishStatus = publishStatus
        self.version = version
        self.path = path
        self.contentClass = contentClass
        self.publishedAt = publishedAt
        self.bytes = bytes
        self.reason = reason
    }

    public static func from(item: PlannedMove, indexedAt: Date) -> ArchiveRecord {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        let meta = item.meta
        return ArchiveRecord(
            id: String(SHA256.hex(Data(item.destinationPath.utf8)).prefix(16)),
            fileName: PathKey.name(item.destinationPath),
            originalName: meta?.originalName ?? item.fileName,
            kind: item.kind.rawValue,
            projectTag: meta?.projectTag ?? "",
            modifiedAt: formatter.string(from: item.modifiedAt),
            platform: meta?.platform ?? "",
            publishStatus: meta?.publishStatus ?? "",
            version: meta?.versionLabel ?? "",
            path: item.destinationPath,
            contentClass: meta?.contentClass ?? "",
            publishedAt: meta?.publishedAt.map { formatter.string(from: $0) } ?? "",
            bytes: item.bytes,
            reason: item.reason
        )
    }
}

public final class ArchiveDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?

    public static func open(path: String) -> ArchiveDatabase? {
        if path != ":memory:" {
            let parent = PathKey.parent(path)
            guard FileManager.default.fileExists(atPath: parent) else { return nil }
        }
        var raw: UnsafeMutableRawPointer?
        let code = path.withCString { pointer in
            chanwu_db_open(pointer, &raw)
        }
        guard code == 0, let raw else { return nil }
        let database = ArchiveDatabase()
        database.handle = raw
        return database
    }

    deinit {
        if let handle {
            chanwu_db_close(handle)
        }
    }

    public func upsert(_ record: ArchiveRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        _ = record.id.withCString { id in
            record.fileName.withCString { fileName in
                record.originalName.withCString { original in
                    record.kind.withCString { kind in
                        record.projectTag.withCString { tag in
                            record.modifiedAt.withCString { modified in
                                record.platform.withCString { platform in
                                    record.publishStatus.withCString { status in
                                        record.version.withCString { version in
                                            record.path.withCString { path in
                                                record.contentClass.withCString { content in
                                                    record.publishedAt.withCString { published in
                                                        record.reason.withCString { reason in
                                                            chanwu_db_upsert(handle, id, fileName, original, kind, tag, modified, platform, status, version, path, content, published, record.bytes, reason)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    public func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        _ = path.withCString { chanwu_db_remove(handle, $0) }
    }

    public func search(_ query: String) -> [ArchiveRecord] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(4)
        var patterns = ["", "", "", ""]
        for (index, term) in terms.enumerated() {
            patterns[index] = like(term)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [] }
        var json: UnsafeMutablePointer<CChar>?
        let code = patterns[0].withCString { a in
            patterns[1].withCString { b in
                patterns[2].withCString { c in
                    patterns[3].withCString { d in
                        chanwu_db_search(handle, a, b, c, d, &json)
                    }
                }
            }
        }
        guard code == 0, let json else { return [] }
        defer { chanwu_db_free(json) }
        let data = Data(String(cString: json).utf8)
        return (try? JSONDecoder().decode([ArchiveRecord].self, from: data)) ?? []
    }

    private func like(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
