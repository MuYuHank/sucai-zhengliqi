public import Foundation

public enum DeskSlot: String, Codable, CaseIterable, Sendable, Identifiable {
    case publishedVideo
    case pendingVideo
    case finishedImage
    case screenshot
    case product
    case webMaintenance
    case seoGeo
    case pendingDelete
    case audio
    case otherMedia

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .publishedVideo: return "视频发布"
        case .pendingVideo: return "视频待发布"
        case .finishedImage: return "图片成品"
        case .screenshot: return "截图"
        case .product: return "产品"
        case .webMaintenance: return "网站维护"
        case .seoGeo: return "SEO GEO"
        case .pendingDelete: return "待删"
        case .audio: return "音频"
        case .otherMedia: return "其他"
        }
    }

    public var defaultRelative: String {
        switch self {
        case .publishedVideo: return "社媒/视频/视频发布"
        case .pendingVideo: return "社媒/视频/视频待发布"
        case .finishedImage: return "社媒/图片/图片成品"
        case .screenshot: return "社媒/图片/截图"
        case .product: return "产品"
        case .webMaintenance: return "网站相关/网站维护"
        case .seoGeo: return "网站相关/SEO GEO"
        case .pendingDelete: return "待删"
        case .audio: return "社媒/音频"
        case .otherMedia: return "其他"
        }
    }
}

public struct RouteRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var nameContains: String
    public var extensions: [String]
    public var pathUnder: String
    public var slot: DeskSlot
    public var note: String

    public static func make(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        nameContains: String = "",
        extensions: [String] = [],
        pathUnder: String = "",
        slot: DeskSlot,
        note: String = ""
    ) -> RouteRule {
        RouteRule(id: id, enabled: enabled, nameContains: nameContains, extensions: extensions, pathUnder: pathUnder, slot: slot, note: note)
    }
}

public struct DeskConfig: Codable, Equatable, Sendable {
    public var schema: Int
    public var onboardingDone: Bool
    public var destinations: [String: String]
    public var extraTags: [String]
    public var pendingVideoDays: Int
    public var localAIEnabled: Bool
    public var ollamaEndpoint: String
    public var ollamaModel: String
    public var renameMessyNames: Bool
    public var rules: [RouteRule]
    public var moveOnly: Bool
    public var youtubeClientID: String
    public var tiktokClientID: String
    public var facebookClientID: String

    public static func standard() -> DeskConfig {
        var destinations: [String: String] = [:]
        for slot in DeskSlot.allCases {
            destinations[slot.rawValue] = slot.defaultRelative
        }
        return DeskConfig(
            schema: 1,
            onboardingDone: false,
            destinations: destinations,
            extraTags: [],
            pendingVideoDays: 14,
            localAIEnabled: false,
            ollamaEndpoint: "http://127.0.0.1:11434",
            ollamaModel: "llama3.2",
            renameMessyNames: true,
            rules: [],
            moveOnly: true,
            youtubeClientID: "",
            tiktokClientID: "",
            facebookClientID: ""
        )
    }

    public func relative(for slot: DeskSlot) -> String {
        let raw = destinations[slot.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        return slot.defaultRelative
    }

    public func reservedTopLevels() -> Set<String> {
        var names: Set<String> = [DefaultLocations.reportFolderName, DefaultLocations.legacyReportFolderName, ".chanwu"]
        for slot in DeskSlot.allCases where slot != .product {
            if let top = relative(for: slot).split(separator: "/").first {
                names.insert(String(top))
            }
        }
        return names
    }
}

public enum DefaultLocations {
    public static func desktop(home: String) -> String {
        PathKey.joining(home, "Desktop")
    }

    /// 新写的周报目录。旧版目录名仍留在 reservedTopLevels，避免已经生成的文件夹被再次扫描。
    public static let reportFolderName = "素材整理器报告"
    public static let legacyReportFolderName = "产物整理器报告"

    public static func reportDirectory(desktop: String) -> String {
        PathKey.joining(desktop, reportFolderName)
    }

    public static let everydayNames = ["Downloads", "Desktop", "Documents", "Projects"]
    public static let developmentNames = [".codex", ".cursor", "Developer"]

    public static func scanRoots(home: String) -> [String] {
        (everydayNames + developmentNames).map { PathKey.joining(home, $0) }
    }

    /// 常用目录在前，开发目录在后。其余位置保持传入的顺序，不按路径字母排序。
    public static func orderedScanRoots(_ roots: [String], home: String) -> [String] {
        let preferred = scanRoots(home: home)
        var seen = Set<String>()
        var incoming: [String] = []
        for root in roots {
            let path = PathKey.normalize(root)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            incoming.append(path)
        }
        let head = preferred.filter { incoming.contains($0) }
        let tail = incoming.filter { !preferred.contains($0) }
        return head + tail
    }
}

public enum ContentClass: String, Codable, CaseIterable, Sendable, Equatable {
    case finalVideo
    case renderFrame
    case codeProject
    case screenshot
    case log
    case cache
    case archive
    case aiImage
    case designSource
    case installer
    case webPage
    case seoDocument
    case audio
    case secret
    case other

    public var displayName: String {
        switch self {
        case .finalVideo: return "成片"
        case .renderFrame: return "渲染帧"
        case .codeProject: return "源码"
        case .screenshot: return "截图"
        case .log: return "日志"
        case .cache: return "缓存"
        case .archive: return "压缩包"
        case .aiImage: return "图片"
        case .designSource: return "设计"
        case .installer: return "安装包"
        case .webPage: return "网页"
        case .seoDocument: return "SEO"
        case .audio: return "音频"
        case .secret: return "密钥"
        case .other: return "其他"
        }
    }
}

public enum Usefulness: String, Codable, Sendable, Equatable {
    case useful
    case probablyUseless
    case leaveUntouched
}

public struct Classification: Equatable, Sendable {
    public var content: ContentClass
    public var usefulness: Usefulness
    public var confidence: Double
    public var reasons: [String]
    public var projectTag: String
    public var version: VersionToken?
}

public enum ProjectTags {
    public static let builtins = ["FCCV1", "案头", "YUUKI"]
    /// 这些文件夹名不是项目。出现在路径里也不会拿来当标签或重命名前缀。
    public static let generic: Set<String> = [
        "output", "outputs", "downloads", "desktop", "documents", "inbox", "dist", "build",
        "release", "export", "exports", "generated", "generations", "video", "videos", "image", "images",
        "sub", "tmp", "temp", "temporary", "untitled", "src", "source", "sources", "out", "in",
        "test", "tests", "fixture", "fixtures", "chanwu", "var", "private", "users", "user", "home",
        "volumes", "volume", "disk", "other", "others", "new", "final", "draft", "drafts", "bin",
        "obj", "public", "assets", "static", "media", "files", "file", "data", "work", "workspace",
        "projects", "project", "backup", "backups", "old", "misc", "cache", "caches", "logs", "log",
        "node_modules", "vendor", "app", "apps",
        "社媒", "产品", "网站相关", "下载", "桌面", "文稿",
    ]
    public static let markers: Set<String> = [
        ".git", "package.json", "package.swift", "cargo.toml", "go.mod", "pyproject.toml",
        "gemfile", "composer.json", "pom.xml", "build.gradle", "cmakelists.txt",
        "readme", "readme.md", "readme.txt",
    ]

    public static func isMarker(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if markers.contains(lowered) { return true }
        return lowered.hasSuffix(".xcodeproj") || lowered.hasSuffix(".xcworkspace")
    }

    public static func isGeneric(_ name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.count < 2 || lowered.hasPrefix(".") { return true }
        return generic.contains(lowered)
    }

    public static func detect(path: String, name: String, extra: [String], roots: Set<String> = []) -> String {
        let known = matchKnown(path: path, name: name, extra: extra)
        if !known.isEmpty { return known }
        let normalizedRoots = Set(roots.map(PathKey.normalize))
        var cursor = PathKey.parent(path)
        var steps = 0
        while cursor != "/" && steps < 64 {
            if normalizedRoots.contains(cursor) {
                let folder = PathKey.name(cursor)
                if !isGeneric(folder) { return folder }
            }
            let next = PathKey.parent(cursor)
            if next == cursor { break }
            cursor = next
            steps += 1
        }
        return ""
    }

    /// 项目根：只认目录里有 package.json / .git / README 这类标记的文件夹。
    /// 「同一文件夹下有好几个文件」不算项目根，否则 renders、site 这类普通文件夹都会变成标签。
    public static func roots(for files: [DeskFile]) -> Set<String> {
        var marked: Set<String> = []
        for file in files {
            let parent = PathKey.parent(file.path)
            if file.siblingNames.contains(where: isMarker), !isGeneric(PathKey.name(parent)) {
                marked.insert(parent)
            }
        }
        return marked
    }

    private static func matchKnown(path: String, name: String, extra: [String]) -> String {
        let tags = (extra + builtins).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let parts = PathKey.components(path) + [name]
        for tag in tags {
            if parts.contains(where: { containsToken($0, tag: tag) }) {
                return tag
            }
        }
        return ""
    }

    private static func containsToken(_ text: String, tag: String) -> Bool {
        if tag.isEmpty || text.isEmpty { return false }
        let ascii = tag.unicodeScalars.allSatisfy(\.isASCII)
        let options: String.CompareOptions = ascii ? [.caseInsensitive] : []
        var rest = text.startIndex..<text.endIndex
        while let found = text.range(of: tag, options: options, range: rest) {
            let before = found.lowerBound == text.startIndex || !isTokenChar(text[text.index(before: found.lowerBound)])
            let after = found.upperBound == text.endIndex || !isTokenChar(text[found.upperBound])
            if before && after { return true }
            if found.upperBound == text.endIndex { break }
            rest = found.upperBound..<text.endIndex
        }
        return false
    }

    private static func isTokenChar(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

public struct VersionToken: Equatable, Sendable {
    public var raw: String
    public var major: Int
    public var minor: Int
    public var revision: Int
    public var isFinal: Bool
    public var dateStamp: Int

    public func isNewer(than other: VersionToken) -> Bool {
        if dateStamp != other.dateStamp { return dateStamp > other.dateStamp }
        if isFinal != other.isFinal { return isFinal }
        if major != other.major { return major > other.major }
        if minor != other.minor { return minor > other.minor }
        return revision > other.revision
    }
}

public enum VersionParser {
    public static func parse(name: String) -> VersionToken? {
        let stem = Sanitizer.stemAndExtension(name).0
        let lowered = stem.lowercased()
        var major = 0
        var minor = 0
        var revision = 0
        var rawParts: [String] = []
        var isFinal = false
        if let match = firstMatch(lowered, pattern: #"(?:^|[_\-. ])v(\d+)(?:[_\.](\d+))?(?:$|[_\-. ])"#) {
            major = Int(match[1]) ?? 0
            minor = match.count > 2 ? (Int(match[2]) ?? 0) : 0
            rawParts.append("v\(major)" + (minor > 0 ? "_\(minor)" : ""))
        } else if let match = firstMatch(lowered, pattern: #"(?:^|[_\-. ])r(\d+)(?:$|[_\-. ])"#) {
            revision = Int(match[1]) ?? 0
            rawParts.append("r\(revision)")
        }
        if lowered.range(of: #"(?:^|[_\-. ])final(?:$|[_\-. ])"#, options: .regularExpression) != nil {
            isFinal = true
            rawParts.append("final")
        }
        var dateStamp = 0
        if let match = firstMatch(stem, pattern: #"(20\d{2})[-_]?(\d{2})[-_]?(\d{2})"#) {
            let year = Int(match[1]) ?? 0
            let month = Int(match[2]) ?? 0
            let day = Int(match[3]) ?? 0
            if (1...12).contains(month), (1...31).contains(day) {
                dateStamp = year * 10_000 + month * 100 + day
                rawParts.append(String(format: "%04d-%02d-%02d", year, month, day))
            }
        }
        if rawParts.isEmpty { return nil }
        return VersionToken(raw: rawParts.joined(separator: "+"), major: major, minor: minor, revision: revision, isFinal: isFinal, dateStamp: dateStamp)
    }

    public static func groupingStem(_ name: String) -> String {
        var stem = Sanitizer.stemAndExtension(name).0.lowercased()
        let patterns = [
            #"[_\-. ]v\d+(?:[_\.]\d+)?"#,
            #"[_\-. ]r\d+"#,
            #"[_\-. ]final"#,
            #"[_\-. ]?20\d{2}[-_]?\d{2}[-_]?\d{2}"#,
        ]
        for pattern in patterns {
            stem = stem.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return stem.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
    }

    private static func firstMatch(_ text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        var parts: [String] = []
        for index in 0..<match.numberOfRanges {
            let part = match.range(at: index)
            if part.location == NSNotFound {
                parts.append("")
            } else if let swift = Range(part, in: text) {
                parts.append(String(text[swift]))
            } else {
                parts.append("")
            }
        }
        return parts
    }
}

public enum RulesEngine {
    public static func firstMatch(_ rules: [RouteRule], name: String, path: String) -> RouteRule? {
        let ext = PathKey.fileExtension(name)
        for rule in rules where rule.enabled {
            let nameNeedle = rule.nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
            let pathNeedle = rule.pathUnder.trimmingCharacters(in: .whitespacesAndNewlines)
            let extensions = rule.extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
            if nameNeedle.isEmpty && pathNeedle.isEmpty && extensions.isEmpty { continue }
            if !nameNeedle.isEmpty && name.range(of: nameNeedle, options: .caseInsensitive) == nil { continue }
            if !pathNeedle.isEmpty && path.range(of: pathNeedle, options: .caseInsensitive) == nil { continue }
            if !extensions.isEmpty && !extensions.contains(ext) { continue }
            return rule
        }
        return nil
    }
}

public enum CollisionNames {
    public static func choose(stem: String, ext: String, when: Date, calendar: Calendar, isTaken: (String) -> Bool) -> String {
        let base = join(stem: stem, ext: ext)
        if !isTaken(base) { return base }
        let day = stamp(when, calendar: calendar, time: false)
        let dated = join(stem: "\(stem)_\(day)", ext: ext)
        if !isTaken(dated) { return dated }
        let clock = stamp(when, calendar: calendar, time: true)
        let timed = join(stem: "\(stem)_\(clock)", ext: ext)
        if !isTaken(timed) { return timed }
        var index = 2
        while index < Limits.collisionLimit {
            let candidate = join(stem: "\(stem)_\(clock)_\(index)", ext: ext)
            if !isTaken(candidate) { return candidate }
            index += 1
        }
        return timed
    }

    private static func join(stem: String, ext: String) -> String {
        ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private static func stamp(_ date: Date, calendar: Calendar, time: Bool) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        if time {
            return String(format: "%04d-%02d-%02d_%02d%02d%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        }
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

public enum AutoRename {
    public static func isMessy(_ name: String) -> Bool {
        let stem = Sanitizer.stemAndExtension(name).0.lowercased()
        let patterns = [
            #"^image[_-]?\d+$"#,
            #"^img[_-]?\d+$"#,
            #"^output(?: \(\d+\))?$"#,
            #"^output[_-]?\d+$"#,
            #"^untitled\d*$"#,
            #"^未命名\d*$"#,
            #"^dsc[_-]?\d+$"#,
            #"^render[_-]?\d+$"#,
        ]
        return patterns.contains { stem.range(of: $0, options: .regularExpression) != nil }
    }

    public static func propose(project: String, content: String, when: Date, ext: String, calendar: Calendar) -> String {
        let word = content.isEmpty ? "文件" : content
        let day = CollisionNamesDebug.day(when, calendar: calendar)
        let stem = project.isEmpty
            ? Sanitizer.fileName("\(word)_\(day)")
            : Sanitizer.fileName("\(project)_\(word)_\(day)")
        let stripped = Sanitizer.stemAndExtension(stem).0
        if ext.isEmpty { return stripped }
        return "\(stripped).\(ext)"
    }
}

enum CollisionNamesDebug {
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

public struct AISuggestion: Equatable, Sendable {
    public var contentClass: ContentClass?
    public var title: String?
    public var confidence: Double
    public var reason: String
}

public struct DeskFile: Equatable, Sendable {
    public var id: String
    public var path: String
    public var name: String
    public var bytes: Int64
    public var modifiedAt: Date
    public var parentNames: [String]
    public var siblingNames: [String]
    public var identification: Identification
    public var ai: AISuggestion?
    public var duration: Double?
    public var frameHash: FrameHash?
}

public struct DeskPlanItem: Equatable, Sendable {
    public var id: String
    public var sourcePath: String
    public var destinationPath: String
    public var fileName: String
    public var originalName: String
    public var bytes: Int64
    public var modifiedAt: Date
    public var identification: Identification
    public var confidence: Double
    public var slot: DeskSlot
    public var disposition: Disposition
    public var reason: String
    public var meta: ItemMeta
}

public struct DeskPlanResult: Equatable, Sendable {
    public var items: [DeskPlanItem]
    public var issues: [ScanIssue]
}

public enum FileClassifier {
    public static func classify(file: DeskFile, tags: [String], roots: Set<String> = []) -> Classification {
        let name = file.name
        let ext = PathKey.fileExtension(name)
        let lowered = name.lowercased()
        let parents = file.parentNames.map { $0.lowercased() }
        let tag = ProjectTags.detect(path: file.path, name: name, extra: tags, roots: roots)
        let version = VersionParser.parse(name: name)
        if Safety.looksLikeSecret(name) {
            return Classification(content: .secret, usefulness: .leaveUntouched, confidence: 0.99, reasons: ["文件名像密钥或凭据"], projectTag: tag, version: version)
        }
        if isScreenshot(lowered) {
            return Classification(content: .screenshot, usefulness: .useful, confidence: 0.9, reasons: ["文件名像截图，不放进图片成品"], projectTag: tag, version: version)
        }
        if isRender(name: lowered, ext: ext, siblings: file.siblingNames) {
            return Classification(content: .renderFrame, usefulness: .probablyUseless, confidence: 0.86, reasons: ["像是中间渲染帧"], projectTag: tag, version: version)
        }
        if ext == "log" || lowered.hasSuffix(".log") || parents.contains("logs") {
            return Classification(content: .log, usefulness: .probablyUseless, confidence: 0.9, reasons: ["日志文件"], projectTag: tag, version: version)
        }
        if parents.contains(where: { ["cache", "caches", ".cache"].contains($0) }) {
            return Classification(content: .cache, usefulness: .probablyUseless, confidence: 0.9, reasons: ["位于缓存目录"], projectTag: tag, version: version)
        }
        if isSEO(lowered, ext: ext) {
            return Classification(content: .seoDocument, usefulness: .useful, confidence: 0.88, reasons: ["像是 SEO / GEO 素材"], projectTag: tag, version: version)
        }
        if ["html", "css", "js", "mjs"].contains(ext) {
            return Classification(content: .webPage, usefulness: .useful, confidence: 0.8, reasons: ["网页文件"], projectTag: tag, version: version)
        }
        if ["swift", "py", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "mm", "rb", "php", "ts", "tsx", "jsx"].contains(ext) {
            return Classification(content: .codeProject, usefulness: .leaveUntouched, confidence: 0.8, reasons: ["源码文件，不移动"], projectTag: tag, version: version)
        }
        if ["dmg", "pkg", "exe", "msi"].contains(ext) {
            return Classification(content: .installer, usefulness: .useful, confidence: 0.9, reasons: ["安装包或交付物"], projectTag: tag, version: version)
        }
        if ["psd", "ai", "fig", "sketch", "afdesign"].contains(ext) {
            return Classification(content: .designSource, usefulness: .useful, confidence: 0.9, reasons: ["设计源文件"], projectTag: tag, version: version)
        }
        if ["zip", "7z", "rar", "tar", "gz", "tgz"].contains(ext) {
            return Classification(content: .archive, usefulness: .useful, confidence: 0.75, reasons: ["压缩包，按产品交付物归档"], projectTag: tag, version: version)
        }
        if isDupe(lowered) {
            return Classification(content: .other, usefulness: .probablyUseless, confidence: 0.7, reasons: ["文件名像旧副本"], projectTag: tag, version: version)
        }
        if file.identification.kind == .video {
            return Classification(content: .finalVideo, usefulness: .useful, confidence: 0.84, reasons: ["视频成片"], projectTag: tag, version: version)
        }
        if file.identification.kind == .audio {
            return Classification(content: .audio, usefulness: .useful, confidence: 0.8, reasons: ["音频"], projectTag: tag, version: version)
        }
        if file.identification.kind == .image {
            if file.identification.source != .unknown {
                var reasons = ["识别为 \(file.identification.source.displayName) 生成的图片"]
                reasons.append(contentsOf: file.identification.evidence.prefix(2))
                return Classification(content: .aiImage, usefulness: .useful, confidence: max(file.identification.confidence, 0.8), reasons: reasons, projectTag: tag, version: version)
            }
            if AutoRename.isMessy(name) {
                return Classification(content: .aiImage, usefulness: .useful, confidence: 0.62, reasons: ["文件名像模型导出的图片"], projectTag: tag, version: version)
            }
            return Classification(content: .other, usefulness: .useful, confidence: 0.4, reasons: ["普通图片，默认不放进成品"], projectTag: tag, version: version)
        }
        return Classification(content: .other, usefulness: .useful, confidence: 0.35, reasons: ["没有更具体的规则"], projectTag: tag, version: version)
    }

    public static func slot(for content: ContentClass, usefulness: Usefulness) -> DeskSlot {
        if usefulness == .probablyUseless { return .pendingDelete }
        switch content {
        case .finalVideo: return .pendingVideo
        case .screenshot: return .screenshot
        case .aiImage: return .finishedImage
        case .designSource, .installer, .archive: return .product
        case .webPage: return .webMaintenance
        case .seoDocument: return .seoGeo
        case .audio: return .audio
        case .renderFrame, .log, .cache: return .pendingDelete
        case .codeProject, .secret, .other: return .otherMedia
        }
    }

    private static func isScreenshot(_ lowered: String) -> Bool {
        ["screenshot", "screen shot", "screen-shot", "截图", "cleanshot", "snipaste", "屏幕快照"].contains { lowered.contains($0) }
    }

    private static func isSEO(_ lowered: String, ext: String) -> Bool {
        if ["llms.txt", "robots.txt", "sitemap.xml"].contains(lowered) { return true }
        if lowered.contains("sitemap") || lowered.contains("llms.txt") { return true }
        let words = ["seo", "geo", "schema", "keyword", "audit"]
        return words.contains { lowered.contains($0) } && ["xml", "json", "csv", "txt", "html", "md"].contains(ext)
    }

    private static func isDupe(_ lowered: String) -> Bool {
        lowered.contains(" 副本") || lowered.contains(" copy") || lowered.hasSuffix(" copy") || lowered.contains("copy of ")
    }

    private static func isRender(name: String, ext: String, siblings: [String]) -> Bool {
        let frame = name.range(of: #"^(frame|render|keyframe|seq)[_\-.]?\d+\.[a-z0-9]+$"#, options: .regularExpression) != nil
        if frame { return true }
        let numbered = name.range(of: #"^\d{3,}\.[a-z0-9]+$"#, options: .regularExpression) != nil
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "exr", "tif", "tiff", "webp"]
        guard imageExts.contains(ext) else { return false }
        let numberedSiblings = siblings.filter { sibling in
            let lower = sibling.lowercased()
            let siblingExt = PathKey.fileExtension(lower)
            guard imageExts.contains(siblingExt) else { return false }
            let stem = Sanitizer.stemAndExtension(lower).0
            return stem.range(of: #"\d{3,}$"#, options: .regularExpression) != nil
        }
        if numbered && numberedSiblings.count >= 5 { return true }
        return numberedSiblings.count >= 8
    }
}

public enum DeskPlanner {
    /// 低于这个置信度时，预览里显示为待确认，默认不勾选。
    public static let preselectMinimum = 0.60

    public static func plan(
        files: [DeskFile],
        library: String,
        config: DeskConfig,
        listings: [PublishedVideo],
        now: Date,
        calendar: Calendar = Calendars.shanghai(),
        pathExists: (String) -> Bool,
        extraRoots: Set<String> = []
    ) -> DeskPlanResult {
        var issues: [ScanIssue] = []
        var drafts: [Draft] = []
        let roots = ProjectTags.roots(for: files).union(extraRoots.map(PathKey.normalize))
        for file in files {
            var classification = FileClassifier.classify(file: file, tags: config.extraTags, roots: roots)
            if let ai = file.ai, classification.content == .other || classification.confidence < 0.6, let suggested = ai.contentClass, ai.confidence >= 0.55 {
                classification.content = suggested
                classification.confidence = max(classification.confidence, ai.confidence)
                classification.reasons.insert(ai.reason, at: 0)
                if suggested == .finalVideo { classification.usefulness = .useful }
            }
            if classification.usefulness == .leaveUntouched {
                issues.append(ScanIssue(id: String(file.id.prefix(12)) + "-skip", path: file.path, message: classification.reasons.first ?? "未改动"))
                continue
            }
            var slot = FileClassifier.slot(for: classification.content, usefulness: classification.usefulness)
            var reason = classification.reasons.joined(separator: "；")
            if let rule = RulesEngine.firstMatch(config.rules, name: file.name, path: file.path) {
                slot = rule.slot
                classification.confidence = max(classification.confidence, 0.99)
                if slot == .pendingDelete { classification.usefulness = .probablyUseless }
                let note = rule.note.isEmpty ? "规则「\(rule.nameContains.isEmpty ? rule.slot.title : rule.nameContains)」" : rule.note
                reason = note + "。" + reason
            }
            var publishStatus = ""
            var platform = ""
            var publishedAt: Date?
            if classification.content == .finalVideo && slot != .pendingDelete {
                let candidate = MatchCandidate(title: Sanitizer.stemAndExtension(file.name).0, duration: file.duration ?? file.frameHash?.duration, hash: file.frameHash)
                if let match = PublishScoring.best(candidate: candidate, listings: listings) {
                    slot = .publishedVideo
                    publishStatus = "published"
                    platform = match.video.platform.rawValue
                    publishedAt = match.video.publishedAt
                    reason += "。已在\(match.video.platform.displayName)发布，相似度 \(Int((match.score * 100).rounded()))%"
                } else {
                    slot = .pendingVideo
                    publishStatus = "pending"
                    if PublishReminder.isStale(status: "pending", since: file.modifiedAt, now: now, days: config.pendingVideoDays) {
                        reason += "。待发布已超过 \(config.pendingVideoDays) 天"
                    }
                }
            }
            let ext = PathKey.fileExtension(file.name)
            var desired = Sanitizer.fileName(file.name)
            var renamed = false
            if config.renameMessyNames && classification.version == nil && AutoRename.isMessy(file.name) {
                let title = file.ai?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let word = (title?.isEmpty == false) ? title! : classification.content.displayName
                desired = AutoRename.propose(project: classification.projectTag, content: word, when: file.modifiedAt, ext: ext, calendar: calendar)
                renamed = desired != file.name
                if renamed { reason += "。原名 \(file.name) 会改成 \(desired)" }
            }
            let relative: String
            if slot == .product {
                let folder = classification.projectTag.isEmpty ? "未分项目" : classification.projectTag
                relative = config.relative(for: .product) + "/" + folder
            } else {
                relative = config.relative(for: slot)
            }
            drafts.append(Draft(
                file: file,
                classification: classification,
                slot: slot,
                reason: reason,
                publishStatus: publishStatus,
                platform: platform,
                publishedAt: publishedAt,
                desired: desired,
                renamed: renamed,
                relative: relative
            ))
        }
        applyVersionRoll(&drafts, config: config)
        var taken: Set<String> = []
        var items: [DeskPlanItem] = []
        for draft in drafts {
            let split = Sanitizer.stemAndExtension(draft.desired)
            let directory = PathKey.joining(library, draft.relative)
            let name = CollisionNames.choose(stem: split.0, ext: split.1, when: draft.file.modifiedAt, calendar: calendar) { candidate in
                let path = PathKey.joining(directory, candidate)
                if taken.contains(path) { return true }
                if path == draft.file.path { return false }
                return pathExists(path)
            }
            let destination = PathKey.joining(directory, name)
            taken.insert(destination)
            let inPlace = destination == draft.file.path
            let disposition: Disposition
            if inPlace {
                disposition = .blocked
            } else if draft.classification.confidence + 0.000_000_1 < preselectMinimum {
                disposition = .optional
            } else {
                disposition = .proposed
            }
            var reason = draft.reason
            if inPlace { reason = "已在目标位置。" + reason }
            if disposition == .optional { reason = "待确认，默认不勾选。" + reason }
            let meta = ItemMeta.make(
                originalName: draft.file.name,
                projectTag: draft.classification.projectTag,
                contentClass: draft.classification.content.rawValue,
                usefulness: draft.classification.usefulness.rawValue,
                publishStatus: draft.publishStatus,
                platform: draft.platform,
                publishedAt: draft.publishedAt,
                versionLabel: draft.classification.version?.raw ?? "",
                renamed: draft.renamed || name != draft.desired,
                inPlace: inPlace
            )
            items.append(DeskPlanItem(
                id: draft.file.id,
                sourcePath: draft.file.path,
                destinationPath: destination,
                fileName: name,
                originalName: draft.file.name,
                bytes: draft.file.bytes,
                modifiedAt: draft.file.modifiedAt,
                identification: draft.file.identification,
                confidence: draft.classification.confidence,
                slot: draft.slot,
                disposition: disposition,
                reason: reason,
                meta: meta
            ))
        }
        return DeskPlanResult(items: items, issues: issues)
    }

    private struct Draft {
        var file: DeskFile
        var classification: Classification
        var slot: DeskSlot
        var reason: String
        var publishStatus: String
        var platform: String
        var publishedAt: Date?
        var desired: String
        var renamed: Bool
        var relative: String
    }

    private static func applyVersionRoll(_ drafts: inout [Draft], config: DeskConfig) {
        var groups: [String: [Int]] = [:]
        for (index, draft) in drafts.enumerated() where draft.slot == .product {
            let key = draft.classification.projectTag.lowercased() + "|" + VersionParser.groupingStem(draft.file.name)
            groups[key, default: []].append(index)
        }
        for indexes in groups.values {
            let tokens = indexes.compactMap { drafts[$0].classification.version }
            guard !tokens.isEmpty, indexes.count > 1 else { continue }
            let ordered = indexes.sorted { lhs, rhs in
                let left = drafts[lhs].classification.version
                let right = drafts[rhs].classification.version
                switch (left, right) {
                case let (left?, right?):
                    return left.isNewer(than: right)
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return drafts[lhs].file.modifiedAt > drafts[rhs].file.modifiedAt
                }
            }
            let history = config.relative(for: .product) + "/" + (drafts[ordered[0]].classification.projectTag.isEmpty ? "未分项目" : drafts[ordered[0]].classification.projectTag) + "/历史版本"
            for (offset, index) in ordered.enumerated() where offset > 0 {
                drafts[index].relative = history
                drafts[index].reason += "。较旧版本，放入历史版本"
            }
            drafts[ordered[0]].reason += "。这是较新的版本，留在产品目录"
        }
    }
}

public enum PublishReminder {
    public static func isStale(status: String, since: Date, now: Date, days: Int) -> Bool {
        guard status == "pending", days > 0 else { return false }
        return now.timeIntervalSince(since) >= Double(days) * 24 * 60 * 60
    }
}

public enum DeskStore {
    public static func load(home: String, store: any FileStore) throws -> DeskConfig {
        let path = StorePaths.deskFile(home: home)
        if !store.exists(path) { return .standard() }
        let config = try Persist.read(DeskConfig.self, path: path, store: store)
        if config.schema > 1 { throw OrganizerError.parse("桌面结构配置来自更新的\(organizerName)") }
        return config
    }

    public static func save(_ config: DeskConfig, home: String, store: any FileStore) throws {
        try Persist.write(config, path: StorePaths.deskFile(home: home), store: store)
    }
}
