public import Foundation

enum Persist {
    static func write<T: Encodable>(_ value: T, path: String, store: any FileStore) throws {
        let data = try JSONFiles.data(value)
        try store.createDirectory(PathKey.parent(path))
        try store.writeFile(path, data: data)
    }

    static func read<T: Decodable>(_ type: T.Type, path: String, store: any FileStore) throws -> T {
        let data = try store.readFile(path, maxBytes: Limits.maxJSONBytes)
        return try JSONFiles.value(type, from: data, path: path)
    }
}

public enum StateStore {
    public static func load(library: String, store: any FileStore, now: Date = Date()) throws -> LibraryState {
        let path = StorePaths.stateFile(library)
        if !store.exists(path) { return .fresh(now: now) }
        let state = try Persist.read(LibraryState.self, path: path, store: store)
        if state.schema > 1 { throw OrganizerError.parse("状态文件来自更新的\(organizerName)") }
        return state
    }

    public static func save(_ state: LibraryState, library: String, store: any FileStore) throws {
        try Persist.write(state, path: StorePaths.stateFile(library), store: store)
    }
}

public enum PreferencesStore {
    public static func load(home: String, store: any FileStore) throws -> AppPreferences {
        let path = StorePaths.preferencesFile(home: home)
        if !store.exists(path) { return .fresh() }
        let preferences = try Persist.read(AppPreferences.self, path: path, store: store)
        if preferences.schema > 1 { throw OrganizerError.parse("偏好设置来自更新的\(organizerName)") }
        return preferences
    }

    public static func save(_ preferences: AppPreferences, home: String, store: any FileStore) throws {
        try Persist.write(preferences, path: StorePaths.preferencesFile(home: home), store: store)
    }
}

public enum PlanStore {
    public static func save(_ plan: MovePlan, store: any FileStore) throws {
        let recomputed = MovePlan.fingerprint(for: plan.items)
        guard recomputed == plan.fingerprint else { throw OrganizerError.planTampered }
        try Persist.write(plan, path: StorePaths.planFile(plan.libraryRoot), store: store)
    }

    public static func load(library: String, store: any FileStore, path: String? = nil) throws -> MovePlan {
        let file = path ?? StorePaths.planFile(library)
        guard store.exists(file) else { throw OrganizerError.io("找不到预览清单 \(file)") }
        let plan = try Persist.read(MovePlan.self, path: file, store: store)
        if plan.schema > 1 { throw OrganizerError.parse("预览清单来自更新的\(organizerName)") }
        if MovePlan.fingerprint(for: plan.items) != plan.fingerprint {
            throw OrganizerError.planTampered
        }
        return plan
    }
}

public enum RunArchive {
    public static func save(_ record: RunRecord, store: any FileStore) throws {
        try store.createDirectory(StorePaths.runsDirectory(record.libraryRoot))
        try Persist.write(record, path: StorePaths.runFile(record.libraryRoot, id: record.id), store: store)
    }

    public static func load(library: String, id: String, store: any FileStore) throws -> RunRecord {
        let path = StorePaths.runFile(library, id: id)
        guard store.exists(path) else { throw OrganizerError.missingRun(id) }
        return try Persist.read(RunRecord.self, path: path, store: store)
    }

    public static func loadAll(library: String, store: any FileStore) throws -> [RunRecord] {
        let directory = StorePaths.runsDirectory(library)
        if !store.exists(directory) { return [] }
        let entries = try store.children(of: directory)
        var records: [RunRecord] = []
        for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".json") {
            let record = try Persist.read(RunRecord.self, path: entry.path, store: store)
            records.append(record)
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }
}

public enum IndexStore {
    public static func load(library: String, store: any FileStore) throws -> Catalog {
        let path = StorePaths.indexFile(library)
        if !store.exists(path) { return .empty() }
        let catalog = try Persist.read(Catalog.self, path: path, store: store)
        if catalog.schema > 1 { throw OrganizerError.parse("索引来自更新的\(organizerName)") }
        return catalog
    }

    public static func save(_ catalog: Catalog, library: String, store: any FileStore) throws {
        var sorted = catalog
        sorted.entries.sort { $0.relativePath < $1.relativePath }
        try Persist.write(sorted, path: StorePaths.indexFile(library), store: store)
    }

    public static func upsert(_ catalog: inout Catalog, entry: IndexEntry) {
        if let index = catalog.entries.firstIndex(where: { $0.relativePath == entry.relativePath || $0.id == entry.id }) {
            catalog.entries[index] = entry
        } else {
            catalog.entries.append(entry)
        }
    }

    public static func remove(relativePath: String, catalog: inout Catalog) {
        catalog.entries.removeAll { $0.relativePath == relativePath }
    }

    public static func search(_ catalog: Catalog, query: String) -> [IndexEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }.filter { !$0.isEmpty }
        return catalog.entries.filter { entry in
            if terms.isEmpty { return true }
            let blob = searchBlob(entry)
            return terms.allSatisfy { blob.contains($0) }
        }.sorted { $0.fileName.lowercased() < $1.fileName.lowercased() }
    }

    public static func stats(_ catalog: Catalog) -> CatalogStats {
        var sourceMap: [SourceTool: (Int, Int64)] = [:]
        var kindMap: [MediaKind: (Int, Int64)] = [:]
        var total: Int64 = 0
        for entry in catalog.entries {
            total += entry.bytes
            let source = sourceMap[entry.source] ?? (0, 0)
            sourceMap[entry.source] = (source.0 + 1, source.1 + entry.bytes)
            let kind = kindMap[entry.kind] ?? (0, 0)
            kindMap[entry.kind] = (kind.0 + 1, kind.1 + entry.bytes)
        }
        let bySource = sourceMap.map { SourceCount(source: $0.key, count: $0.value.0, bytes: $0.value.1) }
            .sorted { $0.count == $1.count ? $0.source.rawValue < $1.source.rawValue : $0.count > $1.count }
        let byKind = kindMap.map { KindCount(kind: $0.key, count: $0.value.0, bytes: $0.value.1) }
            .sorted { $0.count == $1.count ? $0.kind.rawValue < $1.kind.rawValue : $0.count > $1.count }
        return CatalogStats(totalFiles: catalog.entries.count, totalBytes: total, bySource: bySource, byKind: byKind)
    }

    public static func csv(_ catalog: Catalog) -> String {
        var lines = ["文件名,相对路径,来源,类型,置信度,字节,修改时间,原始路径,原名,项目,发布状态,版本"]
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        for entry in catalog.entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            let fields = [
                entry.fileName,
                entry.relativePath,
                entry.source.displayName,
                entry.kind.displayName,
                String(format: "%.2f", entry.confidence),
                String(entry.bytes),
                formatter.string(from: entry.modifiedAt),
                entry.originPath,
                entry.meta?.originalName ?? "",
                entry.meta?.projectTag ?? "",
                entry.meta?.publishStatus ?? "",
                entry.meta?.versionLabel ?? "",
            ].map(csvField)
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    public static func reconcile(_ catalog: inout Catalog, library: String, store: any FileStore) {
        catalog.entries.removeAll { entry in
            !store.exists(PathKey.joining(library, entry.relativePath))
        }
    }

    private static func searchBlob(_ entry: IndexEntry) -> String {
        (
            [
                entry.fileName,
                entry.relativePath,
                entry.originPath,
                entry.source.rawValue,
                entry.source.displayName,
                entry.kind.rawValue,
                entry.kind.displayName,
                entry.meta?.originalName ?? "",
                entry.meta?.projectTag ?? "",
                entry.meta?.contentClass ?? "",
                entry.meta?.publishStatus ?? "",
                entry.meta?.platform ?? "",
                entry.meta?.versionLabel ?? "",
            ] + entry.evidence
        ).joined(separator: "\n").lowercased()
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

struct PendingDocument: Codable, Equatable {
    var paths: [String]
}

public enum PendingStore {
    public static func load(library: String, store: any FileStore) throws -> [String] {
        let path = StorePaths.pendingFile(library)
        if !store.exists(path) { return [] }
        return try Persist.read(PendingDocument.self, path: path, store: store).paths
    }

    public static func save(paths: [String], library: String, store: any FileStore) throws {
        try Persist.write(PendingDocument(paths: paths), path: StorePaths.pendingFile(library), store: store)
    }
}

public enum PendingQueue {
    public static func add(paths: [String], existing: [String], limit: Int = Limits.pendingLimit) -> [String] {
        var output = existing
        var seen = Set(existing.map(PathKey.normalize))
        for path in paths {
            let key = PathKey.normalize(path)
            if seen.contains(key) { continue }
            if output.count >= limit { break }
            seen.insert(key)
            output.append(key)
        }
        return output
    }
}

public struct WatchDebouncer: Equatable, Sendable {
    public struct Observation: Equatable, Sendable {
        public var size: Int64
        public var time: Date
    }

    public var window: TimeInterval
    private var latest: [String: Observation]

    public init(window: TimeInterval = 0.8) {
        self.window = window
        self.latest = [:]
    }

    public var pendingCount: Int { latest.count }

    public mutating func observe(path: String, size: Int64, at time: Date) {
        latest[PathKey.normalize(path)] = Observation(size: size, time: time)
    }

    public mutating func settled(now: Date) -> [String] {
        let ready = latest
            .filter { now.timeIntervalSince($0.value.time) >= window }
            .map(\.key)
            .sorted()
        for path in ready {
            latest.removeValue(forKey: path)
        }
        return ready
    }
}
