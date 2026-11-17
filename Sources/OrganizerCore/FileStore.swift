public import Foundation
import OrganizerPosix

public final class MemoryDisk: FileStore, @unchecked Sendable {
    public struct Node: Equatable {
        public var isDirectory: Bool
        public var isSymlink: Bool
        public var data: Data
        public var modified: Date
    }

    private let lock = NSLock()
    private var nodes: [String: Node]
    public var pathsThatFailRelocate: Set<String> = []

    public init() {
        nodes = ["/": Node(isDirectory: true, isSymlink: false, data: Data(), modified: .distantPast)]
    }

    public func writeFile(_ path: String, data: Data, modified: Date) throws {
        try locked {
            let key = PathKey.normalize(path)
            try ensureParentsUnlocked(of: key, modified: modified)
            nodes[key] = Node(isDirectory: false, isSymlink: false, data: data, modified: modified)
        }
    }

    public func makeDirectory(_ path: String, modified: Date = .distantPast) throws {
        try locked {
            let key = PathKey.normalize(path)
            try ensureDirectoryUnlocked(key, modified: modified)
        }
    }

    public func makeSymlink(_ path: String, modified: Date = .distantPast) throws {
        try locked {
            let key = PathKey.normalize(path)
            try ensureParentsUnlocked(of: key, modified: modified)
            nodes[key] = Node(isDirectory: false, isSymlink: true, data: Data(), modified: modified)
        }
    }

    public func storedData(_ path: String) -> Data? {
        locked { nodes[PathKey.normalize(path)]?.data }
    }

    public func children(of directory: String) throws -> [DiskEntry] {
        try locked { try childrenUnlocked(directory) }
    }

    public func metadata(_ path: String) throws -> DiskMetadata {
        try locked {
            let key = PathKey.normalize(path)
            guard let node = nodes[key] else {
                throw OrganizerError.io("找不到 \(key)")
            }
            return DiskMetadata(
                bytes: Int64(node.data.count),
                modifiedAt: node.modified,
                isDirectory: node.isDirectory && !node.isSymlink,
                isSymlink: node.isSymlink
            )
        }
    }

    public func readPrefix(_ path: String, maxBytes: Int) throws -> Data {
        let data = try readAll(path)
        return Data(data.prefix(max(0, maxBytes)))
    }

    public func readSuffix(_ path: String, maxBytes: Int) throws -> Data {
        let data = try readAll(path)
        if data.count <= maxBytes { return data }
        return Data(data.suffix(max(0, maxBytes)))
    }

    public func readFile(_ path: String, maxBytes: Int) throws -> Data {
        let data = try readAll(path)
        if data.count > maxBytes {
            throw OrganizerError.io("文件过大：\(PathKey.normalize(path))")
        }
        return data
    }

    public func writeFile(_ path: String, data: Data) throws {
        try writeFile(path, data: data, modified: Date())
    }

    public func createDirectory(_ path: String) throws {
        try makeDirectory(path, modified: Date())
    }

    public func exists(_ path: String) -> Bool {
        locked { nodes[PathKey.normalize(path)] != nil }
    }

    public func sameVolume(_ pathA: String, _ pathB: String) -> Bool {
        volume(pathA) == volume(pathB)
    }

    public func relocate(from source: String, to destination: String) throws -> RelocateKind {
        try locked {
            let from = PathKey.normalize(source)
            let to = PathKey.normalize(destination)
            if pathsThatFailRelocate.contains(from) {
                throw OrganizerError.io("无法移动 \(from)")
            }
            guard let node = nodes[from], !node.isDirectory, !node.isSymlink else {
                throw OrganizerError.io("无法移动 \(from)")
            }
            if nodes[to] != nil {
                throw OrganizerError.io("目标已存在：\(to)")
            }
            try ensureParentsUnlocked(of: to, modified: node.modified)
            if sameVolume(from, to) {
                nodes[to] = node
                nodes.removeValue(forKey: from)
                return .moved
            }
            nodes[to] = node
            return .copiedSourceRetained
        }
    }

    public func removeEmptyDirectory(_ path: String) throws {
        try locked {
            let key = PathKey.normalize(path)
            guard key != "/", let node = nodes[key], node.isDirectory, !node.isSymlink else {
                throw OrganizerError.io("不是空文件夹：\(key)")
            }
            let prefix = key + "/"
            if nodes.keys.contains(where: { $0 != key && $0.hasPrefix(prefix) }) {
                throw OrganizerError.io("文件夹不是空的：\(key)")
            }
            nodes.removeValue(forKey: key)
        }
    }

    private func volume(_ path: String) -> String {
        PathKey.components(path).first ?? ""
    }

    private func readAll(_ path: String) throws -> Data {
        try locked {
            let key = PathKey.normalize(path)
            guard let node = nodes[key], !node.isDirectory else {
                throw OrganizerError.io("无法读取 \(key)")
            }
            return node.data
        }
    }

    private func childrenUnlocked(_ directory: String) throws -> [DiskEntry] {
        let dir = PathKey.normalize(directory)
        guard let node = nodes[dir], node.isDirectory, !node.isSymlink else {
            throw OrganizerError.io("不是文件夹：\(dir)")
        }
        let prefix = dir == "/" ? "/" : dir + "/"
        var entries: [DiskEntry] = []
        for (path, child) in nodes where path != dir && path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if rest.contains("/") { continue }
            entries.append(DiskEntry(
                path: path,
                name: String(rest),
                isDirectory: child.isDirectory && !child.isSymlink,
                isSymlink: child.isSymlink
            ))
        }
        return entries.sorted { $0.name < $1.name }
    }

    private func ensureParentsUnlocked(of file: String, modified: Date) throws {
        try ensureDirectoryUnlocked(PathKey.parent(file), modified: modified)
    }

    private func ensureDirectoryUnlocked(_ path: String, modified: Date) throws {
        let key = PathKey.normalize(path)
        let parts = PathKey.components(key)
        var current = "/"
        if let existing = nodes[key] {
            if existing.isDirectory && !existing.isSymlink { return }
            throw OrganizerError.io("路径不是文件夹：\(key)")
        }
        for (index, part) in parts.enumerated() {
            current = current == "/" ? "/" + part : current + "/" + part
            if let existing = nodes[current] {
                if !existing.isDirectory || existing.isSymlink {
                    throw OrganizerError.io("路径不是文件夹：\(current)")
                }
                continue
            }
            let stamp = index == parts.count - 1 ? modified : .distantPast
            nodes[current] = Node(isDirectory: true, isSymlink: false, data: Data(), modified: stamp)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public struct LocalFileStore: FileStore, Sendable {
    public init() {}

    public func children(of directory: String) throws -> [DiskEntry] {
        let path = PathKey.normalize(directory)
        let info = try requireStat(path)
        guard info.isDirectory, !info.isSymlink else {
            throw OrganizerError.io("不是文件夹：\(path)")
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            throw OrganizerError.io("无法列出 \(path)：\(error.localizedDescription)")
        }
        return try names.map { name in
            let child = PathKey.joining(path, name)
            let meta = try requireStat(child)
            return DiskEntry(path: child, name: name, isDirectory: meta.isDirectory, isSymlink: meta.isSymlink)
        }.sorted { $0.name < $1.name }
    }

    public func metadata(_ path: String) throws -> DiskMetadata {
        let info = try requireStat(PathKey.normalize(path))
        return DiskMetadata(bytes: info.bytes, modifiedAt: info.modified, isDirectory: info.isDirectory, isSymlink: info.isSymlink)
    }

    public func readPrefix(_ path: String, maxBytes: Int) throws -> Data {
        let file = PathKey.normalize(path)
        guard let handle = FileHandle(forReadingAtPath: file) else {
            throw OrganizerError.io("无法读取 \(file)")
        }
        defer { try? handle.close() }
        do {
            return try handle.read(upToCount: max(0, maxBytes)) ?? Data()
        } catch {
            throw OrganizerError.io("无法读取 \(file)：\(error.localizedDescription)")
        }
    }

    public func readSuffix(_ path: String, maxBytes: Int) throws -> Data {
        let file = PathKey.normalize(path)
        let info = try requireStat(file)
        guard let handle = FileHandle(forReadingAtPath: file) else {
            throw OrganizerError.io("无法读取 \(file)")
        }
        defer { try? handle.close() }
        do {
            if info.bytes > Int64(maxBytes) {
                try handle.seek(toOffset: UInt64(info.bytes - Int64(maxBytes)))
            }
            return try handle.readToEnd() ?? Data()
        } catch {
            throw OrganizerError.io("无法读取 \(file)：\(error.localizedDescription)")
        }
    }

    public func readFile(_ path: String, maxBytes: Int) throws -> Data {
        let file = PathKey.normalize(path)
        let info = try requireStat(file)
        if info.bytes > Int64(maxBytes) {
            throw OrganizerError.io("文件过大：\(file)")
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: file))
        } catch {
            throw OrganizerError.io("无法读取 \(file)：\(error.localizedDescription)")
        }
    }

    public func writeFile(_ path: String, data: Data) throws {
        let file = PathKey.normalize(path)
        try createDirectory(PathKey.parent(file))
        do {
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        } catch {
            throw OrganizerError.io("无法写入 \(file)：\(error.localizedDescription)")
        }
    }

    public func createDirectory(_ path: String) throws {
        let file = PathKey.normalize(path)
        if let info = posixStat(file) {
            if info.isDirectory && !info.isSymlink { return }
            throw OrganizerError.io("路径不是文件夹：\(file)")
        }
        do {
            try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: true)
        } catch {
            throw OrganizerError.io("无法创建文件夹 \(file)：\(error.localizedDescription)")
        }
    }

    public func removeEmptyDirectory(_ path: String) throws {
        let key = PathKey.normalize(path)
        guard key != "/" else { throw OrganizerError.io("不能移除根目录") }
        let kids = try children(of: key)
        guard kids.isEmpty else { throw OrganizerError.io("文件夹不是空的：\(key)") }
        do {
            try FileManager.default.removeItem(atPath: key)
        } catch {
            throw OrganizerError.io("无法移除空文件夹 \(key)：\(error.localizedDescription)")
        }
    }

    public func exists(_ path: String) -> Bool {
        posixStat(PathKey.normalize(path)) != nil
    }

    public func sameVolume(_ pathA: String, _ pathB: String) -> Bool {
        guard let deviceA = deviceID(existingAncestor(pathA)), let deviceB = deviceID(existingAncestor(pathB)) else {
            return true
        }
        return deviceA == deviceB
    }

    public func relocate(from source: String, to destination: String) throws -> RelocateKind {
        let from = PathKey.normalize(source)
        let to = PathKey.normalize(destination)
        guard exists(from) else { throw OrganizerError.io("找不到 \(from)") }
        if exists(to) { throw OrganizerError.io("目标已存在：\(to)") }
        try createDirectory(PathKey.parent(to))
        if sameVolume(from, to) {
            let errorNumber = from.withCString { sourcePointer in
                to.withCString { destinationPointer in
                    chanwu_rename(sourcePointer, destinationPointer)
                }
            }
            if errorNumber == 0 { return .moved }
            if errorNumber != chanwu_exdev() {
                throw OrganizerError.io("移动失败 \(from) → \(to)（errno \(errorNumber)）")
            }
        }
        do {
            try FileManager.default.copyItem(atPath: from, toPath: to)
        } catch {
            throw OrganizerError.io("复制失败 \(from) → \(to)：\(error.localizedDescription)")
        }
        return .copiedSourceRetained
    }

    private struct StatInfo {
        var isDirectory: Bool
        var isSymlink: Bool
        var bytes: Int64
        var modified: Date
        var device: UInt64
    }

    private func requireStat(_ path: String) throws -> StatInfo {
        guard let info = posixStat(path) else {
            throw OrganizerError.io("找不到 \(path)")
        }
        return info
    }

    private func posixStat(_ path: String) -> StatInfo? {
        var info = ChanwuFileInfo()
        let code = path.withCString { pointer in
            chanwu_lstat(pointer, &info)
        }
        if code != 0 { return nil }
        return StatInfo(
            isDirectory: info.is_dir != 0 && info.is_link == 0,
            isSymlink: info.is_link != 0,
            bytes: info.size,
            modified: Date(timeIntervalSince1970: TimeInterval(info.mtime)),
            device: info.dev
        )
    }

    private func deviceID(_ path: String) -> UInt64? {
        var device: UInt64 = 0
        let code = path.withCString { pointer in
            chanwu_stat_dev(pointer, &device)
        }
        if code != 0 { return nil }
        return device
    }

    private func existingAncestor(_ path: String) -> String {
        var current = PathKey.normalize(path)
        while current != "/" {
            if exists(current) { return current }
            current = PathKey.parent(current)
        }
        return "/"
    }
}

public struct FileSecureStore: SecureStore, Sendable {
    public var directory: String
    public var files: any FileStore

    public init(directory: String, files: any FileStore) {
        self.directory = directory
        self.files = files
    }

    public func read(account: String) throws -> Data? {
        let path = filePath(account)
        guard files.exists(path) else { return nil }
        let data = try files.readFile(path, maxBytes: Limits.maxJSONBytes)
        if data.isEmpty { return nil }
        return data
    }

    public func write(account: String, data: Data) throws {
        try files.createDirectory(directory)
        try files.writeFile(filePath(account), data: data)
    }

    public func delete(account: String) throws {
        try files.createDirectory(directory)
        try files.writeFile(filePath(account), data: Data())
    }

    private func filePath(_ account: String) -> String {
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return PathKey.joining(directory, (safe.isEmpty ? "item" : safe) + ".bin")
    }
}
