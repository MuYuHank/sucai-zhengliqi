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
    public var summary: String
    public var recognizedProject: String
    public var recognitionConfidence: Double
    public var recognizedAt: String
    public var recognizedText: String

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
        reason: String,
        summary: String = "",
        recognizedProject: String = "",
        recognitionConfidence: Double = 0,
        recognizedAt: String = "",
        recognizedText: String = ""
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
        self.summary = summary
        self.recognizedProject = recognizedProject
        self.recognitionConfidence = recognitionConfidence
        self.recognizedAt = recognizedAt
        self.recognizedText = recognizedText
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

    /// 只写识别结果。文件移动时的 upsert 不会清掉这些列。
    public func setRecognition(path: String, summary: String, project: String, confidence: Double, recognizedAt: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        _ = path.withCString { path in
            summary.withCString { summary in
                project.withCString { project in
                    recognizedAt.withCString { recognizedAt in
                        text.withCString { text in
                            chanwu_db_set_recognition(handle, path, summary, project, confidence, recognizedAt, text)
                        }
                    }
                }
            }
        }
    }

    /// 已经识别过的行。搜索面板用它补上目录里没有的摘要和正文。
    public func recognized() -> [ArchiveRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [] }
        var json: UnsafeMutablePointer<CChar>?
        let code = chanwu_db_recognized(handle, &json)
        return decodeRows(code: code, json: json)
    }

    /// 还没有识别过的行。给「识别未处理的文件」用，不改变普通搜索的排序。
    public func unrecognized() -> [ArchiveRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [] }
        var json: UnsafeMutablePointer<CChar>?
        let code = chanwu_db_unrecognized(handle, &json)
        return decodeRows(code: code, json: json)
    }

    private func decodeRows(code: Int32, json: UnsafeMutablePointer<CChar>?) -> [ArchiveRecord] {
        guard code == 0, let json else { return [] }
        defer { chanwu_db_free(json) }
        let data = Data(String(cString: json).utf8)
        return (try? JSONDecoder().decode([ArchiveRecord].self, from: data)) ?? []
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

public enum ArchiveLabels {
    public static func contentClass(_ raw: String) -> String {
        ContentClass(rawValue: raw)?.displayName ?? ""
    }

    public static func kind(_ raw: String) -> String {
        MediaKind(rawValue: raw)?.displayName ?? ""
    }

    public static func publishStatus(_ raw: String) -> String {
        switch raw {
        case "published": return "已发布"
        case "pending": return "待发布"
        case "": return ""
        default: return ""
        }
    }

    public static func platform(_ raw: String) -> String {
        PublishPlatform(rawValue: raw)?.displayName ?? ""
    }
}

public struct TextSpan: Equatable, Sendable {
    public var text: String
    public var emphasized: Bool

    public init(text: String, emphasized: Bool) {
        self.text = text
        self.emphasized = emphasized
    }
}

public enum SearchHighlight {
    public static func spans(in text: String, query: String) -> [TextSpan] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty, !text.isEmpty else { return [TextSpan(text: text, emphasized: false)] }
        var ranges: [Range<String.Index>] = []
        for term in terms {
            var search = text.startIndex
            while search < text.endIndex, let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search..<text.endIndex) {
                ranges.append(found)
                search = found.upperBound
            }
        }
        let merged = merge(ranges.sorted { $0.lowerBound < $1.lowerBound })
        if merged.isEmpty { return [TextSpan(text: text, emphasized: false)] }
        var spans: [TextSpan] = []
        var cursor = text.startIndex
        for range in merged {
            if cursor < range.lowerBound {
                spans.append(TextSpan(text: String(text[cursor..<range.lowerBound]), emphasized: false))
            }
            spans.append(TextSpan(text: String(text[range]), emphasized: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            spans.append(TextSpan(text: String(text[cursor...]), emphasized: false))
        }
        return spans.filter { !$0.text.isEmpty }
    }

    /// 查询打中摘要、识别正文或识别出的项目时，返回匹配附近的一小段。
    public static func recognitionLine(record: ArchiveRecord, query: String, limit: Int = 72) -> String? {
        for field in [record.summary, record.recognizedText, record.recognizedProject] {
            if let snippet = snippet(in: field, query: query, limit: limit) { return snippet }
        }
        return nil
    }

    public static func snippet(in text: String, query: String, limit: Int = 72) -> String? {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard let term = terms.first(where: { text.range(of: $0, options: .caseInsensitive) != nil }),
              let range = text.range(of: term, options: .caseInsensitive) else { return nil }
        let cap = max(limit, term.count)
        let spare = max(cap - text.distance(from: range.lowerBound, to: range.upperBound), 0)
        let beforeBudget = spare / 2
        var start = range.lowerBound
        var walked = 0
        while start > text.startIndex && walked < beforeBudget {
            start = text.index(before: start)
            walked += 1
        }
        var end = range.upperBound
        walked = 0
        let afterBudget = spare - beforeBudget
        while end < text.endIndex && walked < afterBudget {
            end = text.index(after: end)
            walked += 1
        }
        var output = String(text[start..<end])
        if start > text.startIndex { output = "…" + output }
        if end < text.endIndex { output += "…" }
        return output
    }

    private static func merge(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var output: [Range<String.Index>] = []
        for range in ranges {
            if let last = output.last, last.upperBound >= range.lowerBound {
                let upper = last.upperBound > range.upperBound ? last.upperBound : range.upperBound
                output[output.count - 1] = last.lowerBound..<upper
            } else {
                output.append(range)
            }
        }
        return output
    }
}

public enum ArchiveQuery {
    /// 目录里的记录没有识别列。按路径把 sqlite 里的摘要、项目和正文补上去，并带上只在 sqlite 里的行。
    public static func merging(_ catalog: [ArchiveRecord], recognition indexed: [ArchiveRecord]) -> [ArchiveRecord] {
        var byPath: [String: ArchiveRecord] = [:]
        for record in indexed { byPath[record.path] = record }
        var seen = Set<String>()
        var output: [ArchiveRecord] = []
        for record in catalog {
            seen.insert(record.path)
            guard var extra = byPath[record.path] else {
                output.append(record)
                continue
            }
            if extra.summary.isEmpty { extra.summary = record.summary }
            if extra.recognizedProject.isEmpty { extra.recognizedProject = record.recognizedProject }
            if extra.recognizedText.isEmpty { extra.recognizedText = record.recognizedText }
            if extra.recognizedAt.isEmpty { extra.recognizedAt = record.recognizedAt }
            if extra.recognitionConfidence == 0 { extra.recognitionConfidence = record.recognitionConfidence }
            var merged = record
            merged.summary = extra.summary
            merged.recognizedProject = extra.recognizedProject
            merged.recognizedText = extra.recognizedText
            merged.recognizedAt = extra.recognizedAt
            merged.recognitionConfidence = extra.recognitionConfidence
            output.append(merged)
        }
        for record in indexed where !seen.contains(record.path) {
            output.append(record)
        }
        return output
    }

    public static func filter(_ records: [ArchiveRecord], query: String) -> [ArchiveRecord] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !terms.isEmpty else { return records }
        return records.filter { record in
            let haystack = [
                record.fileName,
                record.originalName,
                record.projectTag,
                record.path,
                record.platform,
                record.publishStatus,
                record.version,
                record.kind,
                record.contentClass,
                record.reason,
                record.summary,
                record.recognizedProject,
                record.recognizedText,
                ArchiveLabels.contentClass(record.contentClass),
                ArchiveLabels.kind(record.kind),
                ArchiveLabels.publishStatus(record.publishStatus),
                ArchiveLabels.platform(record.platform),
            ].joined(separator: "\n").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}
