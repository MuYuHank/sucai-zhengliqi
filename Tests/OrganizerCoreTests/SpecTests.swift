import Foundation
#if canImport(XCTest)
import XCTest
#endif
@testable import OrganizerCore

final class SpecTests: XCTestCase {
    func testClassificationRoutesScreenshotsSecretsAndFrames() {
        let config = DeskConfig.standard()
        let shot = file("Screen Shot 2026.png", kind: .image)
        let secret = file("api_key.txt", kind: .text)
        let frame = file("frame_0004.exr", kind: .image)
        let seo = file("llms.txt", kind: .text)
        let installer = file("/work/FCCV1/FCCV1-setup.dmg", name: "FCCV1-setup.dmg", kind: .archive)
        let ai = file("cat_midjourney.png", kind: .image, source: .midjourney)
        let result = DeskPlanner.plan(
            files: [shot, secret, frame, seo, installer, ai],
            library: "/desk",
            config: config,
            listings: [],
            now: date(2026, 11, 16),
            pathExists: { _ in false }
        )
        XCTAssertTrue(result.issues.contains { $0.path.hasSuffix("api_key.txt") })
        XCTAssertFalse(result.items.contains { $0.originalName == "api_key.txt" })
        let screenshot = try! XCTUnwrap(result.items.first { $0.originalName == "Screen Shot 2026.png" })
        XCTAssertTrue(screenshot.destinationPath.contains("社媒/图片/截图"))
        XCTAssertFalse(screenshot.destinationPath.contains("图片成品"))
        XCTAssertTrue(result.items.first { $0.originalName == "frame_0004.exr" }!.destinationPath.contains("/待删/"))
        XCTAssertTrue(result.items.first { $0.originalName == "llms.txt" }!.destinationPath.contains("SEO GEO"))
        XCTAssertTrue(result.items.first { $0.originalName == "FCCV1-setup.dmg" }!.destinationPath.contains("/产品/FCCV1/"))
        XCTAssertTrue(result.items.first { $0.originalName == "cat_midjourney.png" }!.destinationPath.contains("图片成品"))
        XCTAssertEqual(ProjectTags.detect(path: "/work/YUUKI/out", name: "a.png", extra: []), "YUUKI")
    }

    func testVersionOrderAndHistoryRoll() {
        XCTAssertTrue(try! XCTUnwrap(VersionParser.parse(name: "app-v5_1.zip")).isNewer(than: try! XCTUnwrap(VersionParser.parse(name: "app-v5.zip"))))
        XCTAssertTrue(try! XCTUnwrap(VersionParser.parse(name: "app-v2.zip")).isNewer(than: try! XCTUnwrap(VersionParser.parse(name: "app-v1.zip"))))
        XCTAssertTrue(try! XCTUnwrap(VersionParser.parse(name: "app-r15.zip")).isNewer(than: try! XCTUnwrap(VersionParser.parse(name: "app-r3.zip"))))
        XCTAssertTrue(try! XCTUnwrap(VersionParser.parse(name: "app-final.zip")).isNewer(than: try! XCTUnwrap(VersionParser.parse(name: "app-v2.zip"))))
        XCTAssertTrue(try! XCTUnwrap(VersionParser.parse(name: "app-2026-11-16.zip")).isNewer(than: try! XCTUnwrap(VersionParser.parse(name: "app-final.zip"))))
        XCTAssertEqual(VersionParser.groupingStem("FCCV1-setup-v5_1.dmg"), VersionParser.groupingStem("FCCV1-setup-v2.dmg"))

        let older = file("/src/FCCV1-setup-v1.dmg", name: "FCCV1-setup-v1.dmg", kind: .archive)
        let newer = file("/src/FCCV1-setup-v5_1.dmg", name: "FCCV1-setup-v5_1.dmg", kind: .archive)
        let result = DeskPlanner.plan(files: [older, newer], library: "/desk", config: .standard(), listings: [], now: date(2026, 11, 16), pathExists: { _ in false })
        let oldItem = try! XCTUnwrap(result.items.first { $0.originalName.contains("v1") })
        let newItem = try! XCTUnwrap(result.items.first { $0.originalName.contains("v5_1") })
        XCTAssertTrue(newItem.destinationPath.contains("/产品/FCCV1/"))
        XCTAssertFalse(newItem.destinationPath.contains("历史版本"))
        XCTAssertTrue(oldItem.destinationPath.contains("历史版本"))
        XCTAssertEqual(newItem.meta.projectTag, "FCCV1")
    }

    func testCollisionAppendsDateThenTime() {
        let when = date(2026, 11, 16, 9, 8, 7)
        let calendar = Calendars.shanghai()
        var taken: Set<String> = ["成片.mp4", "成片_2026-11-16.mp4"]
        let name = CollisionNames.choose(stem: "成片", ext: "mp4", when: when, calendar: calendar) { taken.contains($0) }
        XCTAssertEqual(name, "成片_2026-11-16_090807.mp4")
        taken.insert(name)
        let next = CollisionNames.choose(stem: "成片", ext: "mp4", when: when, calendar: calendar) { taken.contains($0) }
        XCTAssertEqual(next, "成片_2026-11-16_090807_2.mp4")
    }

    func testMoveOnlyRefusesCrossVolumeAndUndoStillRestores() throws {
        let disk = MemoryDisk()
        let when = date(2026, 11, 16)
        try disk.makeDirectory("/disk/inbox")
        try disk.makeDirectory("/other/inbox")
        try disk.writeFile("/disk/inbox/clip.mp4", data: Data("local".utf8), modified: when)
        try disk.writeFile("/other/inbox/remote.mp4", data: Data("remote".utf8), modified: when)
        let organizer = Organizer(store: disk)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/disk/lib"
        preferences.scanRoots = ["/disk/inbox", "/other/inbox"]
        var state = LibraryState.fresh(now: when)
        state.hasCompletedDryRun = true
        let plan = organizer.scanAndPlan(preferences: preferences, state: state, now: when, desk: .standard())
        let record = try organizer.execute(
            plan: plan,
            request: ExecuteRequest.make(confirmed: true, planFingerprint: plan.fingerprint, selectedIDs: Set(plan.proposed.map(\.id)), intendToApply: true, moveOnly: true),
            state: &state,
            now: when,
            runID: "move-only"
        )
        XCTAssertEqual(record.operations.filter { $0.action == .moved }.count, 1)
        XCTAssertTrue(record.operations.contains { $0.action == .skipped && $0.reason.contains("跨卷") })
        XCTAssertEqual(disk.storedData("/other/inbox/remote.mp4"), Data("remote".utf8))
        XCTAssertNil(disk.storedData("/disk/inbox/clip.mp4"))
        let undo = try organizer.undo(runID: "move-only", library: "/disk/lib", now: when, undoID: "move-undo")
        XCTAssertEqual(undo.operations.first { $0.action == .undone }?.destination, "/disk/inbox/clip.mp4")
        XCTAssertEqual(disk.storedData("/disk/inbox/clip.mp4"), Data("local".utf8))
    }

    func testPublishScoringImportAndParsers() throws {
        XCTAssertEqual(PublishScoring.titleSimilarity("My Cat Video", "my cat video"), 1)
        XCTAssertEqual(PublishScoring.durationScore(12, 12.4), 1)
        XCTAssertEqual(PublishScoring.durationScore(12, 40), 0)
        let black = PerceptualHash.averageHash(gray: [UInt8](repeating: 0, count: 64), width: 8, height: 8)
        var split = [UInt8](repeating: 0, count: 64)
        for index in 0..<32 { split[index] = 255 }
        let half = PerceptualHash.averageHash(gray: split, width: 8, height: 8)
        XCTAssertNotEqual(black, half)
        let hash = FrameHash(values: [half], duration: 12)
        let listings = [
            PublishedVideo.make(id: "yt1", platform: .youtube, title: "My Cat Video", durationSeconds: 12.2, frameHash: hash),
            PublishedVideo.make(id: "tt1", platform: .tiktok, title: "完全不同的标题", durationSeconds: 90),
        ]
        let match = try XCTUnwrap(PublishScoring.best(candidate: MatchCandidate(title: "my cat video", duration: 12, hash: hash), listings: listings))
        XCTAssertEqual(match.video.id, "yt1")
        XCTAssertGreaterThan(match.score, 0.72)
        XCTAssertNil(PublishScoring.best(candidate: MatchCandidate(title: "zzzz qqqq", duration: nil, hash: nil), listings: listings))

        let csv = PublishImport.csv("标题,时长,发布日期,编号,平台\n猫咪,12,2026-11-01,abc,youtube\n", defaultPlatform: .tiktok)
        XCTAssertEqual(csv.first?.platform, .youtube)
        XCTAssertEqual(csv.first?.durationSeconds, 12)
        let json = Data(#"{"videos":[{"id":"fb1","title":"发布了","duration":8,"platform":"facebook"}]}"#.utf8)
        XCTAssertEqual(PublishImport.json(json, defaultPlatform: .youtube).first?.platform, .facebook)
        let youtube = Data(#"{"items":[{"id":{"videoId":"v1"},"snippet":{"title":"片","publishedAt":"2026-11-01T00:00:00Z"},"contentDetails":{"duration":"PT1M2S"}}]}"#.utf8)
        XCTAssertEqual(PublishResponseParser.youtube(youtube).first?.durationSeconds, 62)
        let token = Data(#"{"access_token":"ya29.test"}"#.utf8)
        XCTAssertEqual(PublishResponseParser.accessToken(token), "ya29.test")
        let url = OAuthEndpoints.authorizeURL(platform: .youtube, clientID: "client-1", redirect: "http://127.0.0.1:8765", state: "abc")
        XCTAssertTrue(url.contains("client-1"))
        XCTAssertFalse(url.contains("secret"))
        let form = OAuthEndpoints.tokenForm(platform: .tiktok, code: "code", clientID: "cid", clientSecret: "sek", redirect: "http://127.0.0.1/cb")
        XCTAssertTrue(form.contains("sek"))
        XCTAssertTrue(form.contains("client_key"))
    }

    func testRulesEvaluateInOrder() {
        let first = RouteRule.make(nameContains: "海报", extensions: ["png"], slot: .finishedImage, note: "海报进成品")
        let second = RouteRule.make(nameContains: "海报", extensions: ["png"], slot: .pendingDelete, note: "不该命中")
        let ignored = RouteRule.make(enabled: true, slot: .audio, note: "空规则")
        let matched = RulesEngine.firstMatch([ignored, first, second], name: "春季海报.png", path: "/Downloads/春季海报.png")
        XCTAssertEqual(matched?.note, "海报进成品")
        let plan = DeskPlanner.plan(
            files: [file("春季海报.png", kind: .image)],
            library: "/desk",
            config: config(rules: [first, second]),
            listings: [],
            now: date(2026, 11, 16),
            pathExists: { _ in false }
        )
        XCTAssertTrue(plan.items[0].destinationPath.contains("图片成品"))
        XCTAssertEqual(plan.items[0].disposition, .proposed)
    }

    func testSQLiteSearchKeepsOriginalNameAndTag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chanwu-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try XCTUnwrap(ArchiveDatabase.open(path: root.appendingPathComponent("index.sqlite").path))
        var item = planned("/desk/产品/案头/成片.mp4", original: "image_1234.mp4", tag: "案头")
        database.upsert(ArchiveRecord.from(item: item, indexedAt: date(2026, 11, 16)))
        item = planned("/desk/社媒/视频/视频发布/other.mp4", original: "cat.mp4", tag: "DEMO", status: "published", platform: "youtube")
        database.upsert(ArchiveRecord.from(item: item, indexedAt: date(2026, 11, 16)))
        XCTAssertEqual(database.search("image_1234").count, 1)
        XCTAssertEqual(database.search("案头").first?.projectTag, "案头")
        XCTAssertEqual(database.search("youtube published").count, 1)
        XCTAssertTrue(database.search("不存在").isEmpty)
        database.remove(path: "/desk/产品/案头/成片.mp4")
        XCTAssertTrue(database.search("image_1234").isEmpty)
    }

    func testDeliveryManifestAndZipRoundTrip() throws {
        let now = date(2026, 11, 16)
        let payload = Data("hello-交付".utf8)
        let packed = DeliveryPack.make(project: "FCCV1", files: [("FCCV1/说明.txt", payload)], now: now)
        XCTAssertEqual(packed.manifest.files.count, 1)
        XCTAssertEqual(packed.manifest.files[0].sha256, SHA256.hex(payload))
        XCTAssertEqual(packed.manifest.files[0].bytes, Int64(payload.count))
        let extracted = ZipStore.extract(packed.zip)
        XCTAssertEqual(extracted["FCCV1/说明.txt"], payload)
        let manifestData = try XCTUnwrap(extracted["清单.json"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DeliveryManifest.self, from: manifestData)
        XCTAssertEqual(decoded.project, "FCCV1")
        XCTAssertEqual(decoded.files[0].sha256, SHA256.hex(payload))
    }

    func testMessyNamesRenameAndKeepOriginal() {
        XCTAssertTrue(AutoRename.isMessy("image_1234.png"))
        XCTAssertTrue(AutoRename.isMessy("output (3).mp4"))
        XCTAssertFalse(AutoRename.isMessy("FCCV1-setup-v2.dmg"))
        let renamed = AutoRename.propose(project: "案头", content: "成片", when: date(2026, 11, 16), ext: "mp4", calendar: Calendars.shanghai())
        XCTAssertEqual(renamed, "案头_成片_2026-11-16.mp4")
        let plan = DeskPlanner.plan(
            files: [file("image_1234.png", kind: .image, source: .flux)],
            library: "/desk",
            config: .standard(),
            listings: [],
            now: date(2026, 11, 16),
            pathExists: { _ in false }
        )
        let item = try! XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.originalName, "image_1234.png")
        XCTAssertNotEqual(item.fileName, "image_1234.png")
        XCTAssertTrue(item.fileName.contains("2026-11-16"))
        XCTAssertTrue(item.meta.renamed)
    }

    func testWeeklyReportCountsAndSundayFile() throws {
        let calendar = Calendars.shanghai()
        let sunday = date(2026, 11, 15, 10)
        XCTAssertTrue(ReportSchedule.isSunday(sunday, calendar: calendar))
        XCTAssertFalse(ReportSchedule.isSunday(date(2026, 11, 16), calendar: calendar))
        let files = [
            ReportFile(path: "/desk/a.mp4", bytes: 50, modifiedAt: date(2026, 11, 16), indexedAt: date(2026, 11, 16), contentClass: "finalVideo", publishStatus: "published", inHistory: false),
            ReportFile(path: "/desk/b.mp4", bytes: 10, modifiedAt: date(2026, 11, 10), indexedAt: date(2026, 11, 12), contentClass: "finalVideo", publishStatus: "pending", inHistory: false),
            ReportFile(path: "/desk/frame.exr", bytes: 900, modifiedAt: date(2026, 11, 16), indexedAt: nil, contentClass: "renderFrame", publishStatus: "", inHistory: false),
            ReportFile(path: "/desk/产品/FCCV1/历史版本/old.dmg", bytes: 400, modifiedAt: date(2026, 1, 1), indexedAt: nil, contentClass: "installer", publishStatus: "", inHistory: true),
        ]
        let digest = WeeklyReports.digest(files, now: date(2026, 11, 16), calendar: calendar)
        XCTAssertEqual(digest.produced, 2)
        XCTAssertEqual(digest.archived, 1)
        XCTAssertEqual(digest.published, 1)
        XCTAssertEqual(digest.pending, 1)
        XCTAssertTrue(digest.markdown.contains("本周产出：2"))
        let space = WeeklyReports.space(files)
        XCTAssertEqual(space.largest.first?.path, "/desk/frame.exr")
        XCTAssertEqual(space.reclaimableBytes, 1300)
        let disk = MemoryDisk()
        let path = try WeeklyReports.write(digest, desktop: "/desk", now: date(2026, 11, 16), store: disk)
        XCTAssertTrue(path.contains("产物整理器报告/2026-11-16.md"))
        XCTAssertTrue(disk.exists(path))
        XCTAssertTrue(PublishReminder.isStale(status: "pending", since: date(2026, 10, 1), now: date(2026, 11, 16), days: 14))
        XCTAssertFalse(PublishReminder.isStale(status: "published", since: date(2026, 10, 1), now: date(2026, 11, 16), days: 14))
    }

    func testLocalAIStaysOffUnlessEnabled() {
        let trap = TrapTransport()
        let off = OllamaClassifier(enabled: false, endpoint: "http://127.0.0.1:11434", model: "llama3.2", transport: trap)
        XCTAssertNil(off.suggest(name: "x.png", path: "/x.png", snippet: ""))
        XCTAssertFalse(trap.called)
        let body = OllamaCodec.request(model: "llama3.2", name: "image_9.png", path: "/tmp/image_9.png", snippet: "")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("image_9.png"))
        let response = Data(#"{"response":"建议 {\"contentClass\":\"aiImage\",\"title\":\"海报\",\"confidence\":0.8}"}"#.utf8)
        let suggestion = OllamaCodec.parse(response)
        XCTAssertEqual(suggestion?.contentClass, .aiImage)
        XCTAssertEqual(suggestion?.title, "海报")
        let disabled = DisabledLocalAI()
        XCTAssertNil(disabled.suggest(name: "a", path: "/a", snippet: ""))
    }

    func testProjectTagsSkipGenericFoldersUnlessKnownOrRoot() throws {
        XCTAssertEqual(ProjectTags.detect(path: "/tmp/chanwu_fixture/image_1234.png", name: "image_1234.png", extra: []), "")
        XCTAssertEqual(ProjectTags.detect(path: "/Users/me/Downloads/sub/output/image_1234.png", name: "image_1234.png", extra: []), "")
        XCTAssertEqual(ProjectTags.detect(path: "/Users/me/Desktop/src/dist/untitled/a.png", name: "a.png", extra: []), "")
        XCTAssertEqual(ProjectTags.detect(path: "/work/fccv1/dist/image_1234.png", name: "image_1234.png", extra: []), "FCCV1")
        XCTAssertEqual(ProjectTags.detect(path: "/jobs/案头/tmp/output (3).mp4", name: "output (3).mp4", extra: []), "案头")
        XCTAssertEqual(AutoRename.propose(project: "", content: "图片", when: date(2026, 11, 16), ext: "png", calendar: Calendars.shanghai()), "图片_2026-11-16.png")

        let noisy = file("/tmp/chanwu_fixture/sub/image_1234.png", name: "image_1234.png", kind: .image, source: .flux)
        let known = file("/work/FCCV1/dist/image_1234.png", name: "image_1234.png", kind: .image, source: .flux)
        var extra = DeskConfig.standard()
        extra.extraTags = ["海报组"]
        let custom = file("/jobs/海报组/tmp/output (3).mp4", name: "output (3).mp4", kind: .video)
        var marked = file("/work/SiteKit/image_9.png", name: "image_9.png", kind: .image, source: .flux)
        marked.siblingNames = ["image_9.png", "package.json", "README.md"]
        let left = file("/work/PosterStudio/exports/image_1.png", name: "image_1.png", kind: .image, source: .flux)
        let right = file("/work/PosterStudio/exports/image_2.png", name: "image_2.png", kind: .image, source: .flux)
        let plain = DeskPlanner.plan(files: [noisy, known, custom, marked, left, right], library: "/desk", config: extra, listings: [], now: date(2026, 11, 16), pathExists: { _ in false })

        let noisyItem = try XCTUnwrap(plain.items.first { $0.originalName == "image_1234.png" && $0.sourcePath.contains("chanwu_fixture") })
        XCTAssertEqual(noisyItem.meta.projectTag, "")
        XCTAssertEqual(noisyItem.originalName, "image_1234.png")
        XCTAssertEqual(noisyItem.fileName, "图片_2026-11-16.png")
        XCTAssertFalse(noisyItem.fileName.contains("chanwu"))
        XCTAssertTrue(noisyItem.meta.renamed)

        let knownItem = try XCTUnwrap(plain.items.first { $0.sourcePath.contains("/FCCV1/") })
        XCTAssertEqual(knownItem.meta.projectTag, "FCCV1")
        XCTAssertTrue(knownItem.fileName.hasPrefix("FCCV1_"))

        let customItem = try XCTUnwrap(plain.items.first { $0.originalName == "output (3).mp4" })
        XCTAssertEqual(customItem.meta.projectTag, "海报组")
        XCTAssertEqual(customItem.fileName, "海报组_成片_2026-11-16.mp4")

        let markedItem = try XCTUnwrap(plain.items.first { $0.sourcePath.contains("SiteKit") })
        XCTAssertEqual(markedItem.meta.projectTag, "SiteKit")
        XCTAssertTrue(markedItem.fileName.hasPrefix("SiteKit_"))

        // 同一文件夹下有好几个文件不算项目根：没有 package.json / .git / README 就不打标签。
        let repeated = plain.items.filter { $0.sourcePath.contains("PosterStudio") }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(repeated.allSatisfy { $0.meta.projectTag == "" && !$0.fileName.hasPrefix("PosterStudio_") })
        let frames = (1...3).map { file("/Users/me/Downloads/renders/frame_000\($0).png", name: "frame_000\($0).png", kind: .image) }
        let pages = [file("/Users/me/Downloads/site/index.html", name: "index.html", kind: .code), file("/Users/me/Downloads/site/sitemap.xml", name: "sitemap.xml", kind: .other)]
        let folders = DeskPlanner.plan(files: frames + pages, library: "/desk", config: .standard(), listings: [], now: date(2026, 11, 16), pathExists: { _ in false })
        XCTAssertTrue(folders.items.allSatisfy { $0.meta.projectTag == "" })

        let disk = MemoryDisk()
        let when = date(2026, 11, 16)
        try disk.makeDirectory("/work/SiteKit/output")
        try disk.writeFile("/work/SiteKit/package.json", data: Data("{}\n".utf8), modified: when)
        try disk.writeFile("/work/SiteKit/output/image_1234.png", data: Data("png".utf8), modified: when)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/desk"
        preferences.scanRoots = ["/work/SiteKit"]
        let scanned = Organizer(store: disk).scanAndPlan(preferences: preferences, state: .fresh(now: when), now: when, desk: .standard())
        let scannedItem = try XCTUnwrap(scanned.items.first { $0.meta?.originalName == "image_1234.png" })
        XCTAssertEqual(scannedItem.meta?.projectTag, "SiteKit")
        XCTAssertTrue(scannedItem.fileName.hasPrefix("SiteKit_"))
        XCTAssertEqual(scannedItem.meta?.originalName, "image_1234.png")
    }

    func testLowConfidenceStaysUnchecked() throws {
        let low = file("/inbox/mystery.bin", name: "mystery.bin", kind: .other)
        let plain = file("/inbox/photo.png", name: "photo.png", kind: .image)
        let high = file("/inbox/clip.mp4", name: "clip.mp4", kind: .video)
        let result = DeskPlanner.plan(files: [low, plain, high], library: "/desk", config: .standard(), listings: [], now: date(2026, 11, 16), pathExists: { _ in false })
        let mystery = try XCTUnwrap(result.items.first { $0.originalName == "mystery.bin" })
        let photo = try XCTUnwrap(result.items.first { $0.originalName == "photo.png" })
        let clip = try XCTUnwrap(result.items.first { $0.originalName == "clip.mp4" })
        XCTAssertLessThan(mystery.confidence, DeskPlanner.preselectMinimum)
        XCTAssertLessThan(photo.confidence, DeskPlanner.preselectMinimum)
        XCTAssertGreaterThanOrEqual(clip.confidence, DeskPlanner.preselectMinimum)
        XCTAssertEqual(mystery.disposition, .optional)
        XCTAssertEqual(photo.disposition, .optional)
        XCTAssertEqual(clip.disposition, .proposed)
        XCTAssertTrue(mystery.reason.contains("待确认"))
        XCTAssertTrue(photo.reason.contains("待确认"))
        let preselected = Set(result.items.filter { $0.disposition == .proposed }.map(\.id))
        XCTAssertFalse(preselected.contains(mystery.id))
        XCTAssertFalse(preselected.contains(photo.id))
        XCTAssertTrue(preselected.contains(clip.id))

        let disk = MemoryDisk()
        let when = date(2026, 11, 16)
        try disk.writeFile("/inbox/mystery.bin", data: Data("bin".utf8), modified: when)
        try disk.writeFile("/inbox/clip.mp4", data: Data("mp4".utf8), modified: when)
        var preferences = AppPreferences.fresh()
        preferences.libraryRoot = "/desk"
        preferences.scanRoots = ["/inbox"]
        let plan = Organizer(store: disk).scanAndPlan(preferences: preferences, state: .fresh(now: when), now: when, desk: .standard())
        let plannedLow = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("mystery.bin") })
        let plannedHigh = try XCTUnwrap(plan.items.first { $0.sourcePath.hasSuffix("clip.mp4") })
        XCTAssertEqual(plannedLow.disposition, .optional)
        XCTAssertLessThan(plannedLow.confidence, DeskPlanner.preselectMinimum)
        XCTAssertFalse(plan.preselectedIDs.contains(plannedLow.id))
        XCTAssertTrue(plan.preselectedIDs.contains(plannedHigh.id))
        XCTAssertEqual(plannedHigh.disposition, .proposed)
    }

    func testPackAndReportCommands() throws {
        let disk = MemoryDisk()
        let when = date(2026, 11, 16)
        let payload = Data("交付正文".utf8)
        let old = Data("旧版本".utf8)
        try disk.writeFile("/desk/产品/FCCV1/说明.txt", data: payload, modified: when)
        try disk.writeFile("/desk/产品/FCCV1/历史版本/old.txt", data: old, modified: when)
        try disk.writeFile("/desk/社媒/视频/视频待发布/clip.mp4", data: Data("clip".utf8), modified: when)
        var catalog = Catalog.empty()
        catalog.entries = [
            indexEntry(relative: "产品/FCCV1/说明.txt", name: "说明.txt", bytes: payload.count, when: when, tag: "FCCV1", content: "installer", status: ""),
            indexEntry(relative: "产品/FCCV1/历史版本/old.txt", name: "old.txt", bytes: old.count, when: when, tag: "FCCV1", content: "installer", status: ""),
            indexEntry(relative: "社媒/视频/视频待发布/clip.mp4", name: "clip.mp4", bytes: 4, when: when, tag: "FCCV1", content: "finalVideo", status: "pending"),
        ]
        try IndexStore.save(catalog, library: "/desk", store: disk)

        let missing = CLIRunner.run(.pack(PackFlags(library: "/desk", project: "没有", output: "/out/none.zip")), store: disk, now: when)
        XCTAssertEqual(missing.exitCode, 2)
        XCTAssertFalse(disk.exists("/out/none.zip"))

        let packed = CLIRunner.run(.pack(PackFlags(library: "/desk", project: "fccv1", output: "/out/FCCV1.zip")), store: disk, now: when)
        XCTAssertEqual(packed.exitCode, 0, packed.stderr)
        let zip = try XCTUnwrap(disk.storedData("/out/FCCV1.zip"))
        let extracted = ZipStore.extract(zip)
        XCTAssertEqual(extracted["产品/FCCV1/说明.txt"], payload)
        XCTAssertNil(extracted["产品/FCCV1/历史版本/old.txt"])
        XCTAssertNotNil(extracted["社媒/视频/视频待发布/clip.mp4"])
        let manifestData = try XCTUnwrap(extracted["清单.json"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DeliveryManifest.self, from: manifestData)
        XCTAssertEqual(manifest.files.count, 2)
        XCTAssertTrue(manifest.files.contains { $0.relativePath == "产品/FCCV1/说明.txt" && $0.sha256 == SHA256.hex(payload) && $0.bytes == Int64(payload.count) })
        XCTAssertFalse(manifest.files.contains { $0.relativePath.contains("历史版本") })

        let again = CLIRunner.run(.pack(PackFlags(library: "/desk", project: "FCCV1", output: "/out/FCCV1.zip")), store: disk, now: when)
        XCTAssertEqual(again.exitCode, 2)
        XCTAssertEqual(disk.storedData("/out/FCCV1.zip"), zip)

        let printed = CLIRunner.run(.report(ReportFlags(library: "/desk", desktop: nil, write: false)), store: disk, now: when)
        XCTAssertEqual(printed.exitCode, 0)
        XCTAssertTrue(printed.stdout.contains("本周产出：3"))
        XCTAssertTrue(printed.stdout.contains("仍待发布：1"))
        XCTAssertFalse(disk.exists("/desk/产物整理器报告/2026-11-16.md"))

        let written = CLIRunner.run(.report(ReportFlags(library: "/desk", desktop: "/desk", write: true)), store: disk, now: when)
        XCTAssertEqual(written.exitCode, 0, written.stderr)
        XCTAssertTrue(written.stdout.contains("已写入 /desk/产物整理器报告/2026-11-16.md"))
        XCTAssertTrue(disk.exists("/desk/产物整理器报告/2026-11-16.md"))

        let parsed = try CLIParser.parse(["pack", "--library", "/desk", "--project", "FCCV1", "--output", "/out/a.zip"])
        guard case .pack(let packFlags) = parsed else { return XCTFail() }
        XCTAssertEqual(packFlags.project, "FCCV1")
        let reportParsed = try CLIParser.parse(["report", "--library", "/desk", "--desktop", "/desk", "--write"])
        guard case .report(let reportFlags) = reportParsed else { return XCTFail() }
        XCTAssertEqual(reportFlags.write, true)
        XCTAssertTrue(CLIParser.helpText.contains("chanwu pack"))
        XCTAssertTrue(CLIParser.helpText.contains("chanwu report"))
        XCTAssertThrowsError(try CLIParser.parse(["pack", "--library", "/desk"]))
    }

    private func indexEntry(relative: String, name: String, bytes: Int, when: Date, tag: String, content: String, status: String) -> IndexEntry {
        IndexEntry(
            id: relative,
            relativePath: relative,
            fileName: name,
            source: .unknown,
            kind: .document,
            confidence: 0.9,
            bytes: Int64(bytes),
            modifiedAt: when,
            indexedAt: when,
            originPath: "/src/" + name,
            evidence: [],
            meta: .make(originalName: name, projectTag: tag, contentClass: content, publishStatus: status)
        )
    }

    private func file(_ path: String, name: String? = nil, kind: MediaKind, source: SourceTool = .unknown) -> DeskFile {
        let resolvedName = name ?? PathKey.name(path.hasPrefix("/") ? path : "/in/\(path)")
        let resolvedPath = path.hasPrefix("/") ? path : "/in/\(path)"
        return DeskFile(
            id: resolvedPath,
            path: resolvedPath,
            name: resolvedName,
            bytes: 10,
            modifiedAt: date(2026, 11, 16),
            parentNames: PathKey.components(resolvedPath).dropLast().map { $0 },
            siblingNames: [resolvedName],
            identification: Identification(source: source, kind: kind, confidence: source == .unknown ? 0.3 : 0.9, evidence: []),
            ai: nil,
            duration: nil,
            frameHash: nil
        )
    }

    private func config(rules: [RouteRule]) -> DeskConfig {
        var config = DeskConfig.standard()
        config.rules = rules
        return config
    }

    private func planned(_ path: String, original: String, tag: String, status: String = "", platform: String = "") -> PlannedMove {
        PlannedMove(
            id: path,
            sourcePath: "/src/" + original,
            destinationPath: path,
            fileName: PathKey.name(path),
            bytes: 4,
            modifiedAt: date(2026, 11, 16),
            source: .unknown,
            kind: .video,
            confidence: 0.9,
            evidence: [],
            disposition: .proposed,
            reason: "测试",
            meta: .make(originalName: original, projectTag: tag, publishStatus: status, platform: platform)
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let calendar = Calendars.shanghai()
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) ?? Date(timeIntervalSince1970: 0)
    }
}

private final class TrapTransport: HTTPPosting, @unchecked Sendable {
    var called = false
    func post(url: String, body: Data, timeout: TimeInterval) -> Data? {
        called = true
        return nil
    }
}
