public import Foundation

public struct FrameHash: Codable, Equatable, Sendable {
    public var values: [UInt64]
    public var duration: Double?

    public init(values: [UInt64], duration: Double? = nil) {
        self.values = values
        self.duration = duration
    }
}

public enum PerceptualHash {
    public static func averageHash(gray: [UInt8], width: Int, height: Int) -> UInt64 {
        guard width > 0, height > 0, gray.count >= width * height else { return 0 }
        var samples = [UInt8](repeating: 0, count: 64)
        for row in 0..<8 {
            for column in 0..<8 {
                let x0 = column * width / 8
                let x1 = max(x0 + 1, (column + 1) * width / 8)
                let y0 = row * height / 8
                let y1 = max(y0 + 1, (row + 1) * height / 8)
                var total = 0
                var count = 0
                for y in y0..<y1 {
                    for x in x0..<x1 where y * width + x < gray.count {
                        total += Int(gray[y * width + x])
                        count += 1
                    }
                }
                samples[row * 8 + column] = UInt8(count == 0 ? 0 : total / count)
            }
        }
        let average = samples.reduce(0) { $0 + Int($1) } / 64
        var bits: UInt64 = 0
        for (index, sample) in samples.enumerated() where Int(sample) >= average {
            bits |= 1 << UInt64(index)
        }
        return bits
    }

    public static func hamming(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}

public enum PublishPlatform: String, Codable, CaseIterable, Sendable, Equatable {
    case youtube
    case tiktok
    case facebook

    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .tiktok: return "TikTok"
        case .facebook: return "Facebook"
        }
    }
}

public struct PublishedVideo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var platform: PublishPlatform
    public var title: String
    public var durationSeconds: Double?
    public var publishedAt: Date?
    public var frameHash: FrameHash?

    public static func make(
        id: String,
        platform: PublishPlatform,
        title: String,
        durationSeconds: Double? = nil,
        publishedAt: Date? = nil,
        frameHash: FrameHash? = nil
    ) -> PublishedVideo {
        PublishedVideo(id: id, platform: platform, title: title, durationSeconds: durationSeconds, publishedAt: publishedAt, frameHash: frameHash)
    }
}

public struct PublishedLibrary: Codable, Equatable, Sendable {
    public var schema: Int
    public var videos: [PublishedVideo]

    public static func empty() -> PublishedLibrary {
        PublishedLibrary(schema: 1, videos: [])
    }
}

public struct MatchCandidate: Equatable, Sendable {
    public var title: String
    public var duration: Double?
    public var hash: FrameHash?
}

public struct PublishMatch: Equatable, Sendable {
    public var video: PublishedVideo
    public var score: Double
    public var titleScore: Double
    public var durationScore: Double?
    public var hashScore: Double?
}

public enum PublishScoring {
    public static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs)
        if left.isEmpty || right.isEmpty { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        if union == 0 { return 0 }
        return Double(intersection) / Double(union)
    }

    public static func durationScore(_ lhs: Double, _ rhs: Double) -> Double {
        let gap = abs(lhs - rhs)
        if gap <= 1.5 { return 1 }
        if gap >= 8 { return 0 }
        return 1 - (gap - 1.5) / 6.5
    }

    public static func hashScore(_ lhs: FrameHash, _ rhs: FrameHash) -> Double? {
        guard !lhs.values.isEmpty, !rhs.values.isEmpty else { return nil }
        let distances = lhs.values.map { left in
            rhs.values.map { PerceptualHash.hamming(left, $0) }.min() ?? 64
        }
        let average = Double(distances.reduce(0, +)) / Double(distances.count)
        return 1 - average / 64
    }

    public static func combined(title: Double, duration: Double?, hash: Double?) -> Double {
        switch (hash, duration) {
        case let (hash?, duration?):
            return 0.45 * hash + 0.35 * title + 0.20 * duration
        case let (hash?, nil):
            return 0.55 * hash + 0.45 * title
        case let (nil, duration?):
            return 0.65 * title + 0.35 * duration
        case (nil, nil):
            return title
        }
    }

    public static func best(candidate: MatchCandidate, listings: [PublishedVideo]) -> PublishMatch? {
        var winner: PublishMatch?
        for video in listings {
            let title = titleSimilarity(candidate.title, video.title)
            let duration: Double?
            if let left = candidate.duration, let right = video.durationSeconds {
                duration = durationScore(left, right)
            } else {
                duration = nil
            }
            let hash: Double?
            if let left = candidate.hash, let right = video.frameHash {
                hash = hashScore(left, right)
            } else {
                hash = nil
            }
            let score = combined(title: title, duration: duration, hash: hash)
            let required = (hash == nil && duration == nil) ? 0.84 : 0.72
            guard score + 0.000_000_1 >= required else { continue }
            if winner == nil || score > winner!.score {
                winner = PublishMatch(video: video, score: score, titleScore: title, durationScore: duration, hashScore: hash)
            }
        }
        return winner
    }

    private static func tokens(_ text: String) -> Set<String> {
        var parts: Set<String> = []
        var latin = ""
        func flush() {
            let token = latin.lowercased()
            if token.count >= 2 { parts.insert(token) }
            latin = ""
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.value < 128 {
                latin.unicodeScalars.append(scalar)
            } else {
                flush()
                if scalar.value > 127, !CharacterSet.punctuationCharacters.contains(scalar), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    parts.insert(String(scalar))
                }
            }
        }
        flush()
        return parts
    }
}

public enum PublishImport {
    public static func csv(_ text: String, defaultPlatform: PublishPlatform) -> [PublishedVideo] {
        let rows = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = rows.first else { return [] }
        let columns = splitCSV(header).map { $0.lowercased() }
        func index(_ names: [String]) -> Int? {
            columns.firstIndex { column in names.contains(column) }
        }
        guard let titleIndex = index(["title", "标题", "name"]) else { return [] }
        let durationIndex = index(["duration", "时长", "seconds"])
        let dateIndex = index(["published_at", "发布日期", "date"])
        let idIndex = index(["id", "编号"])
        let platformIndex = index(["platform", "平台"])
        return rows.dropFirst().compactMap { row in
            let fields = splitCSV(row)
            guard titleIndex < fields.count else { return nil }
            let title = fields[titleIndex]
            guard !title.isEmpty else { return nil }
            let platform = platformIndex.flatMap { $0 < fields.count ? PublishPlatform(rawValue: fields[$0].lowercased()) : nil } ?? defaultPlatform
            let duration = durationIndex.flatMap { $0 < fields.count ? Double(fields[$0]) : nil }
            let published = dateIndex.flatMap { $0 < fields.count ? parseDate(fields[$0]) : nil }
            let id = idIndex.flatMap { $0 < fields.count ? fields[$0] : nil }
            return PublishedVideo.make(id: (id?.isEmpty == false ? id! : title), platform: platform, title: title, durationSeconds: duration, publishedAt: published)
        }
    }

    public static func json(_ data: Data, defaultPlatform: PublishPlatform) -> [PublishedVideo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any], let array = dictionary["videos"] as? [[String: Any]] {
            rows = array
        } else {
            return []
        }
        return rows.compactMap { row in
            let title = (row["title"] as? String) ?? (row["标题"] as? String) ?? ""
            guard !title.isEmpty else { return nil }
            let platform = (row["platform"] as? String).flatMap(PublishPlatform.init(rawValue:)) ?? defaultPlatform
            let duration = row["duration"] as? Double ?? (row["duration"] as? Int).map(Double.init)
            let id = (row["id"] as? String) ?? title
            let published = (row["published_at"] as? String).flatMap(parseDate)
            return PublishedVideo.make(id: id, platform: platform, title: title, durationSeconds: duration, publishedAt: published)
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: text)
    }

    private static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if quoted, let peek = iterator.next() {
                    if peek == "\"" {
                        current.append("\"")
                    } else {
                        quoted = false
                        if peek == "," {
                            fields.append(current)
                            current = ""
                        } else {
                            current.append(peek)
                        }
                    }
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}

public enum OAuthEndpoints {
    public static func authorizeURL(platform: PublishPlatform, clientID: String, redirect: String, state: String) -> String {
        let id = encode(clientID)
        let back = encode(redirect)
        let stamp = encode(state)
        switch platform {
        case .youtube:
            return "https://accounts.google.com/o/oauth2/v2/auth?client_id=\(id)&redirect_uri=\(back)&response_type=code&scope=\(encode("https://www.googleapis.com/auth/youtube.readonly"))&state=\(stamp)&access_type=offline"
        case .tiktok:
            return "https://www.tiktok.com/v2/auth/authorize/?client_key=\(id)&redirect_uri=\(back)&response_type=code&scope=video.list&state=\(stamp)"
        case .facebook:
            return "https://www.facebook.com/v19.0/dialog/oauth?client_id=\(id)&redirect_uri=\(back)&response_type=code&scope=user_videos&state=\(stamp)"
        }
    }

    public static func tokenURL(platform: PublishPlatform) -> String {
        switch platform {
        case .youtube: return "https://oauth2.googleapis.com/token"
        case .tiktok: return "https://open.tiktokapis.com/v2/oauth/token/"
        case .facebook: return "https://graph.facebook.com/v19.0/oauth/access_token"
        }
    }

    public static func listingsURL(platform: PublishPlatform) -> String {
        switch platform {
        case .youtube:
            return "https://www.googleapis.com/youtube/v3/search?forMine=true&type=video&part=snippet&maxResults=50"
        case .tiktok:
            return "https://open.tiktokapis.com/v2/video/list/?fields=id,title,duration,create_time"
        case .facebook:
            return "https://graph.facebook.com/v19.0/me/videos?fields=id,title,length,created_time"
        }
    }

    public static func tokenForm(platform: PublishPlatform, code: String, clientID: String, clientSecret: String, redirect: String) -> String {
        let pairs = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "client_key": platform == .tiktok ? clientID : "",
        ]
        return pairs
            .filter { !$0.value.isEmpty }
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .sorted()
            .joined(separator: "&")
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }
}

public enum PublishResponseParser {
    public static func accessToken(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let token = object["access_token"] as? String, !token.isEmpty { return token }
        if let nested = object["data"] as? [String: Any], let token = nested["access_token"] as? String, !token.isEmpty { return token }
        return nil
    }

    public static func youtube(_ data: Data) -> [PublishedVideo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let snippet = item["snippet"] as? [String: Any]
            let title = snippet?["title"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let id = (item["id"] as? [String: Any])?["videoId"] as? String ?? (item["id"] as? String) ?? title
            let published = (snippet?["publishedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let duration = (item["contentDetails"] as? [String: Any])?["duration"] as? String
            return PublishedVideo.make(id: id, platform: .youtube, title: title, durationSeconds: isoDuration(duration), publishedAt: published)
        }
    }

    public static func tiktok(_ data: Data) -> [PublishedVideo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let videos = (object["data"] as? [String: Any])?["videos"] as? [[String: Any]] ?? object["videos"] as? [[String: Any]] ?? []
        return videos.compactMap { video in
            let title = video["title"] as? String ?? ""
            guard !title.isEmpty else { return nil }
            let id = video["id"] as? String ?? title
            let duration = video["duration"] as? Double ?? (video["duration"] as? Int).map(Double.init)
            let published: Date?
            if let seconds = video["create_time"] as? Double {
                published = Date(timeIntervalSince1970: seconds)
            } else if let seconds = video["create_time"] as? Int {
                published = Date(timeIntervalSince1970: Double(seconds))
            } else {
                published = nil
            }
            return PublishedVideo.make(id: id, platform: .tiktok, title: title, durationSeconds: duration, publishedAt: published)
        }
    }

    public static func facebook(_ data: Data) -> [PublishedVideo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let title = (row["title"] as? String) ?? (row["description"] as? String) ?? ""
            guard !title.isEmpty else { return nil }
            let id = row["id"] as? String ?? title
            let duration = row["length"] as? Double ?? (row["length"] as? Int).map(Double.init)
            let published = (row["created_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return PublishedVideo.make(id: id, platform: .facebook, title: title, durationSeconds: duration, publishedAt: published)
        }
    }

    private static func isoDuration(_ text: String?) -> Double? {
        guard let text, text.hasPrefix("PT") else { return nil }
        var seconds = 0.0
        var number = ""
        for character in text.dropFirst(2) {
            if character.isNumber || character == "." {
                number.append(character)
            } else if let value = Double(number) {
                switch character {
                case "H": seconds += value * 3600
                case "M": seconds += value * 60
                case "S": seconds += value
                default: break
                }
                number = ""
            }
        }
        return seconds > 0 ? seconds : nil
    }
}

public enum PublishedStore {
    public static func load(home: String, store: any FileStore) throws -> PublishedLibrary {
        let path = StorePaths.publishedFile(home: home)
        if !store.exists(path) { return .empty() }
        return try Persist.read(PublishedLibrary.self, path: path, store: store)
    }

    public static func save(_ library: PublishedLibrary, home: String, store: any FileStore) throws {
        try Persist.write(library, path: StorePaths.publishedFile(home: home), store: store)
    }
}

public protocol HTTPPosting: Sendable {
    func post(url: String, body: Data, timeout: TimeInterval) -> Data?
}

public struct DisabledLocalAI: LocalClassifier, Sendable {
    public init() {}
    public func suggest(name: String, path: String, snippet: String) -> AISuggestion? { nil }
}

public protocol LocalClassifier: Sendable {
    func suggest(name: String, path: String, snippet: String) -> AISuggestion?
}

public enum OllamaCodec {
    public static func request(model: String, name: String, path: String, snippet: String) -> Data {
        let prompt = "只返回 JSON。根据文件名判断 contentClass（finalVideo、renderFrame、screenshot、aiImage、designSource、installer、webPage、seoDocument、audio、other）、title、confidence。文件名：\(name)。路径：\(path)。片段：\(snippet.prefix(400))"
        let object: [String: Any] = ["model": model, "prompt": prompt, "stream": false]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    public static func parse(_ data: Data) -> AISuggestion? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = object["response"] as? String ?? ""
        let payload = extractJSON(text) ?? data
        guard let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        let name = body["contentClass"] as? String ?? ""
        let confidence = body["confidence"] as? Double ?? 0
        let title = body["title"] as? String
        return AISuggestion(contentClass: ContentClass(rawValue: name), title: title, confidence: confidence, reason: "本地模型建议 \(name)")
    }

    private static func extractJSON(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return Data(text[start...end].utf8)
    }
}

public struct OllamaClassifier: LocalClassifier, Sendable {
    public var enabled: Bool
    public var endpoint: String
    public var model: String
    public var transport: any HTTPPosting

    public init(enabled: Bool, endpoint: String, model: String, transport: any HTTPPosting) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.model = model
        self.transport = transport
    }

    public func suggest(name: String, path: String, snippet: String) -> AISuggestion? {
        guard enabled else { return nil }
        let body = OllamaCodec.request(model: model, name: name, path: path, snippet: snippet)
        let url = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/generate"
        guard let data = transport.post(url: url, body: body, timeout: 1.5) else { return nil }
        return OllamaCodec.parse(data)
    }
}

public struct SpaceItem: Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    public var reason: String
}

public struct SpaceReport: Equatable, Sendable {
    public var largest: [SpaceItem]
    public var reclaimable: [SpaceItem]
    public var reclaimableBytes: Int64
}

public struct ReportFile: Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    public var modifiedAt: Date
    public var indexedAt: Date?
    public var contentClass: String
    public var publishStatus: String
    public var inHistory: Bool

    public init(
        path: String,
        bytes: Int64,
        modifiedAt: Date,
        indexedAt: Date?,
        contentClass: String,
        publishStatus: String,
        inHistory: Bool
    ) {
        self.path = path
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.indexedAt = indexedAt
        self.contentClass = contentClass
        self.publishStatus = publishStatus
        self.inHistory = inHistory
    }
}

public struct WeeklyDigest: Equatable, Sendable {
    public var weekStart: Date
    public var produced: Int
    public var archived: Int
    public var published: Int
    public var pending: Int
    public var markdown: String
}

public enum ReportSchedule {
    public static func isSunday(_ date: Date, calendar: Calendar = Calendars.shanghai()) -> Bool {
        calendar.component(.weekday, from: date) == 1
    }

    public static func weekStart(_ date: Date, calendar: Calendar = Calendars.shanghai()) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let start = calendar.date(byAdding: .day, value: -(weekday - 1), to: calendar.startOfDay(for: date)) ?? date
        return start
    }

    public static func fileName(_ date: Date, calendar: Calendar = Calendars.shanghai()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

public enum WeeklyReports {
    public static func space(_ files: [ReportFile], limit: Int = 10) -> SpaceReport {
        let largest = files.sorted { $0.bytes > $1.bytes }.prefix(limit).map {
            SpaceItem(path: $0.path, bytes: $0.bytes, reason: "体积")
        }
        let reclaimable = files.filter { file in
            file.inHistory || ["renderFrame", "cache", "log"].contains(file.contentClass)
        }.sorted { $0.bytes > $1.bytes }.map { file in
            let reason: String
            if file.inHistory { reason = "历史版本" }
            else if file.contentClass == "renderFrame" { reason = "渲染帧" }
            else if file.contentClass == "cache" { reason = "缓存" }
            else { reason = "日志" }
            return SpaceItem(path: file.path, bytes: file.bytes, reason: reason)
        }
        return SpaceReport(largest: Array(largest), reclaimable: reclaimable, reclaimableBytes: reclaimable.reduce(0) { $0 + $1.bytes })
    }

    public static func digest(_ files: [ReportFile], now: Date, calendar: Calendar = Calendars.shanghai()) -> WeeklyDigest {
        let start = ReportSchedule.weekStart(now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
        func inWeek(_ date: Date) -> Bool { date >= start && date < end }
        let produced = files.filter { inWeek($0.modifiedAt) }.count
        let archived = files.filter { $0.indexedAt.map(inWeek) ?? false }.count
        let published = files.filter { $0.publishStatus == "published" && inWeek($0.indexedAt ?? $0.modifiedAt) }.count
        let pending = files.filter { $0.publishStatus == "pending" }.count
        let markdown = """
        # 产物整理器周报

        周起始：\(ReportSchedule.fileName(start, calendar: calendar).replacingOccurrences(of: ".md", with: ""))

        - 本周产出：\(produced)
        - 本周归档：\(archived)
        - 本周发布：\(published)
        - 仍待发布：\(pending)

        待发布只是提醒。这里没有任何删除操作。
        """
        return WeeklyDigest(weekStart: start, produced: produced, archived: archived, published: published, pending: pending, markdown: markdown)
    }

    public static func files(catalog: Catalog, library: String) -> [ReportFile] {
        catalog.entries.map { entry in
            ReportFile(
                path: PathKey.joining(library, entry.relativePath),
                bytes: entry.bytes,
                modifiedAt: entry.modifiedAt,
                indexedAt: entry.indexedAt,
                contentClass: entry.meta?.contentClass ?? "",
                publishStatus: entry.meta?.publishStatus ?? "",
                inHistory: entry.relativePath.contains("历史版本")
            )
        }
    }

    public static func write(_ digest: WeeklyDigest, desktop: String, now: Date, store: any FileStore) throws -> String {
        let directory = DefaultLocations.reportDirectory(desktop: desktop)
        let path = PathKey.joining(directory, ReportSchedule.fileName(now))
        try store.createDirectory(directory)
        try store.writeFile(path, data: Data(digest.markdown.utf8))
        return path
    }
}

public struct DeliveryFile: Codable, Equatable, Sendable {
    public var relativePath: String
    public var bytes: Int64
    public var sha256: String
}

public struct DeliveryManifest: Codable, Equatable, Sendable {
    public var schema: Int
    public var project: String
    public var createdAt: Date
    public var files: [DeliveryFile]
}

public enum ZipStore {
    public static func archive(files: [(name: String, data: Data)], when: Date = Date()) -> Data {
        var locals = Data()
        var central = Data()
        var count: UInt16 = 0
        let calendar = Calendars.shanghai()
        let stamp = dosTime(when, calendar: calendar)
        for file in files {
            let name = Data(file.name.utf8)
            let crc = Checksum.crc32(file.data)
            let size = UInt32(file.data.count)
            let offset = UInt32(locals.count)
            locals.append(localHeader(name: name, crc: crc, size: size, time: stamp.time, date: stamp.date))
            locals.append(name)
            locals.append(file.data)
            central.append(centralHeader(name: name, crc: crc, size: size, time: stamp.time, date: stamp.date, offset: offset))
            central.append(name)
            count += 1
        }
        var end = Data()
        end.append(le32(0x06054b50))
        end.append(le16(0))
        end.append(le16(0))
        end.append(le16(count))
        end.append(le16(count))
        end.append(le32(UInt32(central.count)))
        end.append(le32(UInt32(locals.count)))
        end.append(le16(0))
        var output = locals
        output.append(central)
        output.append(end)
        return output
    }

    public static func extract(_ data: Data) -> [String: Data] {
        var files: [String: Data] = [:]
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 30 <= bytes.count {
            let signature = u32(bytes, offset)
            if signature != 0x04034b50 { break }
            let method = u16(bytes, offset + 8)
            let compressed = Int(u32(bytes, offset + 18))
            let nameLength = Int(u16(bytes, offset + 26))
            let extra = Int(u16(bytes, offset + 28))
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extra
            guard dataStart + compressed <= bytes.count else { break }
            let name = String(decoding: Data(bytes[nameStart..<nameStart + nameLength]), as: UTF8.self)
            if method == 0 {
                files[name] = Data(bytes[dataStart..<dataStart + compressed])
            }
            offset = dataStart + compressed
        }
        return files
    }

    private static func localHeader(name: Data, crc: UInt32, size: UInt32, time: UInt16, date: UInt16) -> Data {
        var data = Data()
        data.append(le32(0x04034b50))
        data.append(le16(20))
        data.append(le16(0x0800))
        data.append(le16(0))
        data.append(le16(time))
        data.append(le16(date))
        data.append(le32(crc))
        data.append(le32(size))
        data.append(le32(size))
        data.append(le16(UInt16(name.count)))
        data.append(le16(0))
        return data
    }

    private static func centralHeader(name: Data, crc: UInt32, size: UInt32, time: UInt16, date: UInt16, offset: UInt32) -> Data {
        var data = Data()
        data.append(le32(0x02014b50))
        data.append(le16(20))
        data.append(le16(20))
        data.append(le16(0x0800))
        data.append(le16(0))
        data.append(le16(time))
        data.append(le16(date))
        data.append(le32(crc))
        data.append(le32(size))
        data.append(le32(size))
        data.append(le16(UInt16(name.count)))
        data.append(le16(0))
        data.append(le16(0))
        data.append(le16(0))
        data.append(le16(0))
        data.append(le32(0))
        data.append(le32(offset))
        return data
    }

    private static func dosTime(_ date: Date, calendar: Calendar) -> (time: UInt16, date: UInt16) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(max(0, (parts.year ?? 1980) - 1980))
        let dosDate = (year << 9) | (UInt16(parts.month ?? 1) << 5) | UInt16(parts.day ?? 1)
        let dosTime = (UInt16(parts.hour ?? 0) << 11) | (UInt16(parts.minute ?? 0) << 5) | UInt16((parts.second ?? 0) / 2)
        return (dosTime, dosDate)
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}

enum Checksum {
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xffff_ffff
    }
}

public enum DeliveryPack {
    public static func make(project: String, files: [(relativePath: String, data: Data)], now: Date) -> (zip: Data, manifest: DeliveryManifest) {
        let listed = files.map { file in
            DeliveryFile(relativePath: file.relativePath, bytes: Int64(file.data.count), sha256: SHA256.hex(file.data))
        }
        let manifest = DeliveryManifest(schema: 1, project: project, createdAt: now, files: listed)
        let manifestData = (try? JSONFiles.data(manifest)) ?? Data()
        var payload = files.map { ($0.relativePath, $0.data) }
        payload.append(("清单.json", manifestData))
        return (ZipStore.archive(files: payload, when: now), manifest)
    }
}
