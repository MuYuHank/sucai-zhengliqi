public import Foundation

public let organizerVersion = "1.1.0"
public let organizerName = "素材整理器"

public enum Limits {
    public static let sniffBytes = 128 * 1024
    public static let sniffCeiling: Int64 = 64 * 1024 * 1024
    public static let maxSidecarBytes = 1_000_000
    public static let maxJSONBytes = 32 * 1024 * 1024
    public static let maxFilesDefault = 100_000
    public static let maxDepthDefault = 8
    public static let pendingLimit = 5_000
    public static let collisionLimit = 9_999
}

public enum Copy {
    public static let firstRunNote = "首次运行为演练，未移动任何文件。确认清单无误后，再运行一次才会真正移动。"
    public static let explicitDryRunNote = "这次是演练，未移动任何文件。"
    public static func appliedNote(moveOnly: Bool) -> String {
        if moveOnly {
            return "已按确认结果移动文件。可以用这条记录撤销。在其他磁盘上的文件留在原处，没有复制。"
        }
        return "已按确认结果移动文件。可以用这条记录撤销。跨卷的文件只复制，源文件仍留在原地。"
    }

    public static var appliedNote: String { appliedNote(moveOnly: true) }

    public static func neverDeletes(moveOnly: Bool) -> String {
        if moveOnly {
            return "本工具不会删除文件。同一块磁盘上直接移动；在其他磁盘上的文件会留在原处，不会复制。撤销也不会删除文件。"
        }
        return "本工具不会删除文件。同一块磁盘上直接移动；其他磁盘上的文件只复制并保留源文件。撤销也不会删除副本。"
    }

    public static var neverDeletes: String { neverDeletes(moveOnly: true) }
    public static let undoEmpty = "这条记录里没有可以撤销的移动。"
    public static let undoCopyKept = "跨卷副本已留在素材库。撤销不会删除文件，源文件本来就还在。"
    public static let undoMissing = "目标已不在原处，没有改动其余文件。"
    public static let undoConflict = "原路径已被占用，为避免覆盖，这个文件没有移回。"
}

public enum OrganizerError: Error, Equatable, Sendable, CustomStringConvertible {
    case confirmationRequired
    case planFingerprintMismatch
    case planTampered
    case missingRun(String)
    case missingLibrary
    case io(String)
    case parse(String)

    public var description: String {
        switch self {
        case .confirmationRequired:
            return "需要先确认预览。勾选文件并确认后才会继续。这次没有移动任何文件。"
        case .planFingerprintMismatch:
            return "预览清单和确认时不一致。请重新扫描后再确认。"
        case .planTampered:
            return "预览清单的指纹对不上，可能被改动过。请重新扫描。"
        case .missingRun(let id):
            return "找不到运行记录 \(id)。"
        case .missingLibrary:
            return "还没有设置素材库。"
        case .io(let message):
            return message
        case .parse(let message):
            return message
        }
    }
}

public enum SourceTool: String, Codable, CaseIterable, Sendable, Equatable {
    case comfyUI = "comfyui"
    case stableDiffusion = "stable-diffusion"
    case midjourney
    case chatGPT = "chatgpt"
    case flux
    case leonardo
    case ideogram
    case novelAI = "novelai"
    case invokeAI = "invokeai"
    case kling
    case runway
    case luma
    case pika
    case sora
    case suno
    case udio
    case cursor
    case claude
    case unknown

    public var displayName: String {
        switch self {
        case .comfyUI: return "ComfyUI"
        case .stableDiffusion: return "Stable Diffusion"
        case .midjourney: return "Midjourney"
        case .chatGPT: return "ChatGPT"
        case .flux: return "Flux"
        case .leonardo: return "Leonardo"
        case .ideogram: return "Ideogram"
        case .novelAI: return "NovelAI"
        case .invokeAI: return "InvokeAI"
        case .kling: return "可灵"
        case .runway: return "Runway"
        case .luma: return "Luma"
        case .pika: return "Pika"
        case .sora: return "Sora"
        case .suno: return "Suno"
        case .udio: return "Udio"
        case .cursor: return "Cursor"
        case .claude: return "Claude"
        case .unknown: return "未识别"
        }
    }

    public var directoryName: String { displayName }
}

public enum MediaKind: String, Codable, CaseIterable, Sendable, Equatable {
    case image
    case video
    case audio
    case document
    case text
    case code
    case model
    case subtitle
    case mesh
    case archive
    case other

    public var displayName: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .document: return "文档"
        case .text: return "文本"
        case .code: return "代码"
        case .model: return "模型"
        case .subtitle: return "字幕"
        case .mesh: return "三维"
        case .archive: return "压缩包"
        case .other: return "其他"
        }
    }

    public var directoryName: String { displayName }

    public var isLooseMedia: Bool {
        switch self {
        case .image, .video, .audio: return true
        default: return false
        }
    }
}

public enum Disposition: String, Codable, CaseIterable, Sendable, Equatable {
    case proposed
    case optional
    case blocked
}

public enum FileAction: String, Codable, CaseIterable, Sendable, Equatable {
    case wouldMove
    case moved
    case copiedSourceRetained
    case skipped
    case failed
    case undone
}

public enum RunMode: String, Codable, CaseIterable, Sendable, Equatable {
    case dryRun
    case applied
    case undo
}

public enum RelocateKind: String, Codable, CaseIterable, Sendable, Equatable {
    case moved
    case copiedSourceRetained
}

public struct UserRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var keyword: String
    public var source: SourceTool
    public var kind: MediaKind?
    public var enabled: Bool

    public static func make(
        id: String = UUID().uuidString,
        keyword: String,
        source: SourceTool,
        kind: MediaKind? = nil,
        enabled: Bool = true
    ) -> UserRule {
        UserRule(id: id, keyword: keyword, source: source, kind: kind, enabled: enabled)
    }
}

public struct Identification: Codable, Equatable, Sendable {
    public var source: SourceTool
    public var kind: MediaKind
    public var confidence: Double
    public var evidence: [String]
}

public struct ScanIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var message: String
}

public struct PlannedMove: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourcePath: String
    public var destinationPath: String
    public var fileName: String
    public var bytes: Int64
    public var modifiedAt: Date
    public var source: SourceTool
    public var kind: MediaKind
    public var confidence: Double
    public var evidence: [String]
    public var disposition: Disposition
    public var reason: String
    public var meta: ItemMeta? = nil
    /// 桌面结构里的槽位。旧清单没有这个字段时保持 nil，界面再按目标路径判断。
    public var deskSlot: String? = nil

    public var destinationRelative: String {
        destinationPath
    }
}

public struct ItemMeta: Codable, Equatable, Sendable {
    public var originalName: String
    public var projectTag: String
    public var contentClass: String
    public var usefulness: String
    public var publishStatus: String
    public var platform: String
    public var publishedAt: Date?
    public var versionLabel: String
    public var renamed: Bool
    public var inPlace: Bool

    public static func make(
        originalName: String,
        projectTag: String = "",
        contentClass: String = "",
        usefulness: String = "",
        publishStatus: String = "",
        platform: String = "",
        publishedAt: Date? = nil,
        versionLabel: String = "",
        renamed: Bool = false,
        inPlace: Bool = false
    ) -> ItemMeta {
        ItemMeta(
            originalName: originalName,
            projectTag: projectTag,
            contentClass: contentClass,
            usefulness: usefulness,
            publishStatus: publishStatus,
            platform: platform,
            publishedAt: publishedAt,
            versionLabel: versionLabel,
            renamed: renamed,
            inPlace: inPlace
        )
    }
}

public enum PreviewSelection {
    /// 待删默认不勾。只有这一组全部是置信度 ≥ 90% 的渲染帧、缓存或日志时才预先勾上。
    public static let autoDeleteConfidence = 0.90
    public static let autoDeleteClasses: Set<String> = ["renderFrame", "cache", "log"]
    /// 界面上标成「低」的项（低于 75%）默认不勾，即使它仍是建议移动。
    public static let lowConfidence = 0.75

    public static func initialIDs(_ items: [PlannedMove]) -> Set<String> {
        let proposed = items.filter { $0.disposition == .proposed }
        let deletes = proposed.filter { $0.deskSlot == DeskSlot.pendingDelete.rawValue }
        let others = proposed.filter { item in
            item.deskSlot != DeskSlot.pendingDelete.rawValue
                && item.confidence + 0.000_000_1 >= lowConfidence
        }
        let autoDelete = !deletes.isEmpty && deletes.allSatisfy { item in
            item.confidence + 0.000_000_1 >= autoDeleteConfidence
                && autoDeleteClasses.contains(item.meta?.contentClass ?? "")
        }
        return Set((autoDelete ? others + deletes : others).map(\.id))
    }
}

public struct MovePlan: Codable, Equatable, Sendable {
    public var schema: Int
    public var fingerprint: String
    public var libraryRoot: String
    public var createdAt: Date
    public var items: [PlannedMove]
    public var issues: [ScanIssue]

    public var proposed: [PlannedMove] { items.filter { $0.disposition == .proposed } }
    public var optionalItems: [PlannedMove] { items.filter { $0.disposition == .optional } }
    public var blocked: [PlannedMove] { items.filter { $0.disposition == .blocked } }
    /// 预览默认勾选的文件。置信度低于阈值的待确认项不在这里。
    public var preselectedIDs: Set<String> { PreviewSelection.initialIDs(items) }

    public static func fingerprint(for items: [PlannedMove]) -> String {
        let lines = items.map { item in
            [
                item.id,
                item.sourcePath,
                item.destinationPath,
                item.disposition.rawValue,
                item.source.rawValue,
                item.kind.rawValue,
            ].joined(separator: "|")
        }
        return SHA256.hex(Data(lines.joined(separator: "\n").utf8))
    }
}

public struct RunOperation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var source: String
    public var destination: String
    public var action: FileAction
    public var reason: String
    public var bytes: Int64
    public var sourceTool: SourceTool
    public var kind: MediaKind
    /// 这次移动新建的目录，从最深到最浅。撤销时只删除其中已经空了的，不碰事先就存在的文件夹。旧记录没有这个字段。
    public var createdDirectories: [String]? = nil
}

public struct RunRecord: Codable, Equatable, Sendable, Identifiable {
    public var schema: Int
    public var id: String
    public var startedAt: Date
    public var finishedAt: Date
    public var mode: RunMode
    public var libraryRoot: String
    public var planFingerprint: String
    public var undoOfRunID: String?
    public var note: String
    public var operations: [RunOperation]

    public var movedCount: Int {
        operations.filter { $0.action == .moved || $0.action == .copiedSourceRetained || $0.action == .undone }.count
    }
}

public struct IndexEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var relativePath: String
    public var fileName: String
    public var source: SourceTool
    public var kind: MediaKind
    public var confidence: Double
    public var bytes: Int64
    public var modifiedAt: Date
    public var indexedAt: Date
    public var originPath: String
    public var evidence: [String]
    public var meta: ItemMeta? = nil
}

public struct Catalog: Codable, Equatable, Sendable {
    public var schema: Int
    public var entries: [IndexEntry]

    public static func empty() -> Catalog {
        Catalog(schema: 1, entries: [])
    }
}

public struct SourceCount: Equatable, Sendable {
    public var source: SourceTool
    public var count: Int
    public var bytes: Int64
}

public struct KindCount: Equatable, Sendable {
    public var kind: MediaKind
    public var count: Int
    public var bytes: Int64
}

public struct CatalogStats: Equatable, Sendable {
    public var totalFiles: Int
    public var totalBytes: Int64
    public var bySource: [SourceCount]
    public var byKind: [KindCount]
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var schema: Int
    public var libraryRoot: String
    public var scanRoots: [String]
    public var minimumConfidence: Double
    public var includeUnidentifiedMedia: Bool
    public var maxDepth: Int
    public var watchEnabled: Bool
    public var userRules: [UserRule]
    /// nil 跟随系统。light / dark 是这次选择的外观，不是钥匙串。
    public var appearance: String? = nil

    public static func fresh() -> AppPreferences {
        AppPreferences(
            schema: 1,
            libraryRoot: "",
            scanRoots: [],
            minimumConfidence: 0.70,
            includeUnidentifiedMedia: false,
            maxDepth: Limits.maxDepthDefault,
            watchEnabled: false,
            userRules: [],
            appearance: nil
        )
    }
}

public enum AppearanceChoice: String, Codable, Sendable, Equatable {
    case system
    case light
    case dark

    public static func parse(_ raw: String?) -> AppearanceChoice {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return .system
        }
    }

    /// `-SucaiAppearance dark|light`。其它值当作没传。
    public static func launchOverride(arguments: [String]) -> AppearanceChoice? {
        guard let index = arguments.firstIndex(of: "-SucaiAppearance") else { return nil }
        let next = arguments.index(after: index)
        guard arguments.indices.contains(next) else { return nil }
        switch arguments[next].lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    public static func resolve(saved: String?, arguments: [String]) -> AppearanceChoice {
        if let override = launchOverride(arguments: arguments) { return override }
        return parse(saved)
    }
}

/// 工具栏状态按页面分开。预览里的移动说明不会跟着出现在空间或周报。
public struct PageNotes: Equatable, Sendable {
    public var values: [String: String]
    public init(values: [String: String] = [:]) { self.values = values }
    public mutating func set(_ text: String, page: String) { values[page] = text }
    public func text(for page: String) -> String { values[page] ?? "" }

    /// 撤销之后，待整理不再留着「可以用这条记录撤销」。
    public func afterUndo(preview: String, note: String) -> PageNotes {
        var copy = self
        copy.set(note, page: preview)
        return copy
    }
}

public enum SidebarAnnouncement {
    public static func label(title: String, badge: Int, unit: String? = nil) -> String {
        guard badge > 0 else { return title }
        if let unit, !unit.isEmpty { return "\(title)，\(badge) \(unit)" }
        return "\(title)，\(badge)"
    }
}

public enum UndoRoute: Equatable, Sendable {
    /// 当前窗口的撤销栈（文本、删除规则，以及第一响应者自己的撤销）。
    case windowAction
    /// 主窗口是 key，而且这个窗口没有别的可撤销操作时，才撤销文件移动。
    case fileMove
    case none
}

public enum UndoRouting {
    public static func undo(responderCanUndo: Bool, windowCanUndo: Bool, keyWindowIsMain: Bool) -> UndoRoute {
        if responderCanUndo || windowCanUndo { return .windowAction }
        if keyWindowIsMain { return .fileMove }
        return .none
    }

    public static func redo(responderCanRedo: Bool, windowCanRedo: Bool) -> UndoRoute {
        if responderCanRedo || windowCanRedo { return .windowAction }
        return .none
    }
}

public enum SearchRowText {
    /// 文件夹名和项目标签相同时只写一次。搜索里的「产品 › FCCV1 · FCCV1」就是这个。
    public static func subtitle(category: String, folder: String, projectTag: String, when: String) -> String {
        let place = folder.isEmpty || folder == category ? category : "\(category) › \(folder)"
        var parts = [place]
        if !projectTag.isEmpty && projectTag != folder {
            parts.append(projectTag)
        }
        if !when.isEmpty { parts.append(when) }
        return parts.joined(separator: " · ")
    }
}

public struct LibraryState: Codable, Equatable, Sendable {
    public var schema: Int
    public var hasCompletedDryRun: Bool
    public var createdAt: Date
    public var minimumConfidence: Double
    public var includeUnidentifiedMedia: Bool
    public var maxDepth: Int
    public var watchEnabled: Bool
    public var userRules: [UserRule]

    public static func fresh(now: Date = Date()) -> LibraryState {
        LibraryState(
            schema: 1,
            hasCompletedDryRun: false,
            createdAt: now,
            minimumConfidence: 0.70,
            includeUnidentifiedMedia: false,
            maxDepth: Limits.maxDepthDefault,
            watchEnabled: false,
            userRules: []
        )
    }

    public func applying(_ preferences: AppPreferences) -> LibraryState {
        var copy = self
        copy.minimumConfidence = preferences.minimumConfidence
        copy.includeUnidentifiedMedia = preferences.includeUnidentifiedMedia
        copy.maxDepth = preferences.maxDepth
        copy.watchEnabled = preferences.watchEnabled
        copy.userRules = preferences.userRules
        return copy
    }
}

public struct ExecuteRequest: Equatable, Sendable {
    public var confirmed: Bool
    public var planFingerprint: String
    public var selectedIDs: Set<String>
    public var intendToApply: Bool
    public var moveOnly: Bool

    public static func make(
        confirmed: Bool,
        planFingerprint: String,
        selectedIDs: Set<String>,
        intendToApply: Bool,
        moveOnly: Bool = false
    ) -> ExecuteRequest {
        ExecuteRequest(
            confirmed: confirmed,
            planFingerprint: planFingerprint,
            selectedIDs: selectedIDs,
            intendToApply: intendToApply,
            moveOnly: moveOnly
        )
    }
}

public struct ScanOptions: Sendable {
    public var maxFiles: Int
    public var sniffCeiling: Int64

    public static func make(maxFiles: Int = Limits.maxFilesDefault, sniffCeiling: Int64 = Limits.sniffCeiling) -> ScanOptions {
        ScanOptions(maxFiles: maxFiles, sniffCeiling: sniffCeiling)
    }
}

public enum HotkeyModifiers {
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096
}

public struct HotkeyPreference: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var display: String

    public static func make(keyCode: UInt32, carbonModifiers: UInt32, display: String) -> HotkeyPreference {
        HotkeyPreference(keyCode: keyCode, carbonModifiers: carbonModifiers, display: display)
    }

    public static var `default`: HotkeyPreference {
        make(keyCode: 31, carbonModifiers: HotkeyModifiers.command | HotkeyModifiers.option, display: "⌥⌘O")
    }
}

public struct SealedPreferences: Codable, Equatable, Sendable {
    public var schema: Int
    public var installID: String
    public var hotkey: HotkeyPreference

    public static func makeNew(installID: String = UUID().uuidString, hotkey: HotkeyPreference = .default) -> SealedPreferences {
        SealedPreferences(schema: 1, installID: installID, hotkey: hotkey)
    }

    public func encoded() throws -> Data {
        try JSONFiles.encoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SealedPreferences {
        do {
            return try JSONFiles.decoder().decode(SealedPreferences.self, from: data)
        } catch {
            throw OrganizerError.parse("无法解析快捷键设置")
        }
    }
}

public enum PathKey {
    public static func normalize(_ path: String) -> String {
        if path.isEmpty { return "/" }
        let prefixed = path.hasPrefix("/") ? path : "/" + path
        let parts = prefixed.split(separator: "/", omittingEmptySubsequences: true)
        var output: [Substring] = []
        for part in parts {
            if part == "." { continue }
            if part == ".." {
                if !output.isEmpty { output.removeLast() }
                continue
            }
            output.append(part)
        }
        if output.isEmpty { return "/" }
        return "/" + output.joined(separator: "/")
    }

    public static func components(_ path: String) -> [String] {
        let normalized = normalize(path)
        if normalized == "/" { return [] }
        return normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public static func isInsideOrEqual(_ path: String, root: String) -> Bool {
        let pathParts = components(path)
        let rootParts = components(root)
        guard pathParts.count >= rootParts.count else { return false }
        return Array(pathParts.prefix(rootParts.count)) == rootParts
    }

    public static func parent(_ path: String) -> String {
        let parts = components(path)
        if parts.count <= 1 { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    public static func name(_ path: String) -> String {
        components(path).last ?? ""
    }

    public static func joining(_ root: String, _ relative: String) -> String {
        let base = normalize(root)
        let safe = relative.split(separator: "/").filter { $0 != "." && $0 != ".." && !$0.isEmpty }
        if safe.isEmpty { return base }
        let tail = safe.joined(separator: "/")
        if base == "/" { return "/" + tail }
        return base + "/" + tail
    }

    public static func relative(file: String, root: String) -> String? {
        let fileParts = components(file)
        let rootParts = components(root)
        guard fileParts.count >= rootParts.count else { return nil }
        guard Array(fileParts.prefix(rootParts.count)) == rootParts else { return nil }
        return fileParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        if dot == name.startIndex { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

enum Sanitizer {
    static func fileName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "\0", with: "")
        name = name.replacingOccurrences(of: "/", with: "")
        name = name.replacingOccurrences(of: "\\", with: "")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return "未命名" }
        if name.count <= 180 { return name }
        let ext = PathKey.fileExtension(name)
        if ext.isEmpty {
            return String(name.prefix(180))
        }
        let keep = max(1, 180 - (ext.count + 1))
        let stem = name.dropLast(ext.count + 1)
        return String(stem.prefix(keep)) + "." + ext
    }

    static func collisionName(stem: String, ext: String, index: Int) -> String {
        if ext.isEmpty { return "\(stem) (\(index))" }
        return "\(stem) (\(index)).\(ext)"
    }

    static func stemAndExtension(_ name: String) -> (String, String) {
        let ext = PathKey.fileExtension(name)
        if ext.isEmpty { return (name, "") }
        let stem = String(name.dropLast(ext.count + 1))
        return (stem, ext)
    }
}

public enum Safety {
    public static let blockedTopLevel: Set<String> = [
        "System", "usr", "bin", "sbin", "etc", "var", "Library", "Applications",
        "private", "dev", "proc", "sys", "boot",
    ]

    public static let ignoredDirectoryNames: Set<String> = [
        ".git", "node_modules", "__pycache__", ".build", "DerivedData", ".chanwu",
        ".Trash", "Pods", "Carthage", ".swiftpm", ".svn",
        ".cache", ".next", ".turbo", ".parcel-cache", ".gradle", "xcuserdata",
        "cache", "caches", "Cache", "Caches",
    ]

    public static let projectMarkers: Set<String> = [
        ".git", "Package.swift", "package.json", "pyproject.toml", "Cargo.toml",
        "go.mod", "Gemfile", "composer.json", "pom.xml", "build.gradle", "CMakeLists.txt",
    ]

    public static let outputDirectoryNames: Set<String> = [
        "output", "outputs", "generated", "generations", "exports",
    ]

    public static let partialExtensions: Set<String> = [
        "part", "crdownload", "download", "tmp", "partial", "filepart", "opdownload",
    ]

    public static let junkNames: Set<String> = [
        ".ds_store", "thumbs.db", "desktop.ini",
    ]

    public static let wideRoots: Set<String> = [
        "/home", "/Users", "/Volumes",
    ]

    public static func isProtected(_ path: String) -> Bool {
        let normalized = PathKey.normalize(path)
        if normalized == "/" { return true }
        guard let first = PathKey.components(normalized).first else { return true }
        return blockedTopLevel.contains(first)
    }

    public static func looksLikeSecret(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == ".env" || lowered.hasPrefix(".env.") { return true }
        if lowered == "id_rsa" || lowered == "id_dsa" || lowered.hasSuffix(".pem") { return true }
        let markers = ["credential", "credentials", "secret", "password", ".env"]
        if markers.contains(where: { lowered.contains($0) }) { return true }
        if lowered.contains("keyframe") || lowered.contains("keyboard") || lowered == "monkey" || lowered.hasPrefix("monkey.") {
            return false
        }
        let tokens = ["_key", "-key", ".key", "apikey", "api_key", "privatekey", "private_key", "auth.json", "token.json", "cookies"]
        return tokens.contains(where: { lowered.contains($0) }) || lowered == "key" || lowered == "keys" || lowered.hasPrefix("key.")
    }

    public static func isAppBundle(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".app")
    }
}

public enum Calendars {
    public static func shanghai() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
        return calendar
    }
}

public enum UndoSummary {
    public static func sentence(restored: Int, failed: Int, keptCopies: Int, movedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        let stamp = formatter.string(from: movedAt)
        var pieces = ["\(stamp) 的移动里，已把 \(restored) 个文件移回原处"]
        if failed > 0 { pieces.append("\(failed) 个没能移回") }
        if keptCopies > 0 { pieces.append("\(keptCopies) 个是留在其他磁盘上的副本，没有删除") }
        return pieces.joined(separator: "，") + "。"
    }
}

public enum RunStats {
    public static func movedToday(runs: [RunRecord], now: Date, calendar: Calendar = Calendars.shanghai()) -> (count: Int, bytes: Int64) {
        let undone = Set(runs.compactMap(\.undoOfRunID))
        let operations = runs.filter { record in
            record.mode == .applied
                && !undone.contains(record.id)
                && calendar.isDate(record.finishedAt, inSameDayAs: now)
        }.flatMap(\.operations).filter { $0.action == .moved }
        return (operations.count, operations.reduce(Int64(0)) { $0 + $1.bytes })
    }
}

public enum ByteFormat {
    public static func string(bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[index])
    }
}

public enum PlanGate {
    public static func allows(_ identification: Identification, state: LibraryState) -> Bool {
        if identification.source != .unknown {
            return identification.confidence + 0.000_000_1 >= state.minimumConfidence
        }
        return state.includeUnidentifiedMedia && identification.kind.isLooseMedia
    }
}

enum JSONFiles {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func data<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder().encode(value)
        } catch {
            throw OrganizerError.parse("无法编码 JSON：\(error)")
        }
    }

    static func value<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try decoder().decode(T.self, from: data)
        } catch let error as OrganizerError {
            throw error
        } catch {
            throw OrganizerError.parse("无法解析 \(path)：\(error.localizedDescription)")
        }
    }
}

public enum StorePaths {
    public static func chanwuDirectory(_ library: String) -> String {
        PathKey.joining(library, ".chanwu")
    }

    public static func stateFile(_ library: String) -> String {
        PathKey.joining(chanwuDirectory(library), "state.json")
    }

    public static func indexFile(_ library: String) -> String {
        PathKey.joining(chanwuDirectory(library), "index.json")
    }

    public static func planFile(_ library: String) -> String {
        PathKey.joining(chanwuDirectory(library), "last-plan.json")
    }

    public static func runsDirectory(_ library: String) -> String {
        PathKey.joining(chanwuDirectory(library), "runs")
    }

    public static func runFile(_ library: String, id: String) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return PathKey.joining(runsDirectory(library), "\(safe.isEmpty ? "run" : safe).json")
    }

    public static func pendingFile(_ library: String) -> String {
        PathKey.joining(chanwuDirectory(library), "pending.json")
    }

    public static func sqliteFile(_ library: String) -> String {
        PathKey.joining(chanwuDirectory(library), "index.sqlite")
    }

    public static func deskFile(home: String) -> String {
        PathKey.joining(PathKey.joining(home, ".chanwu"), "desk.json")
    }

    public static func publishedFile(home: String) -> String {
        PathKey.joining(PathKey.joining(home, ".chanwu"), "published.json")
    }

    public static func preferencesFile(home: String) -> String {
        PathKey.joining(PathKey.joining(home, ".chanwu"), "preferences.json")
    }

    public static func distributionFile(home: String) -> String {
        PathKey.joining(PathKey.joining(home, ".chanwu"), "distribution.json")
    }

    public static func sealedDirectory(home: String) -> String {
        PathKey.joining(PathKey.joining(home, ".chanwu"), "sealed")
    }
}

public struct DiskEntry: Equatable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
}

public struct DiskMetadata: Equatable, Sendable {
    public var bytes: Int64
    public var modifiedAt: Date
    public var isDirectory: Bool
    public var isSymlink: Bool
}

public protocol FileStore: Sendable {
    func children(of directory: String) throws -> [DiskEntry]
    func metadata(_ path: String) throws -> DiskMetadata
    func readPrefix(_ path: String, maxBytes: Int) throws -> Data
    func readSuffix(_ path: String, maxBytes: Int) throws -> Data
    func readFile(_ path: String, maxBytes: Int) throws -> Data
    func writeFile(_ path: String, data: Data) throws
    func createDirectory(_ path: String) throws
    func removeEmptyDirectory(_ path: String) throws
    func exists(_ path: String) -> Bool
    func sameVolume(_ pathA: String, _ pathB: String) -> Bool
    func relocate(from source: String, to destination: String) throws -> RelocateKind
}

public protocol SecureStore: Sendable {
    func read(account: String) throws -> Data?
    func write(account: String, data: Data) throws
    func delete(account: String) throws
}
