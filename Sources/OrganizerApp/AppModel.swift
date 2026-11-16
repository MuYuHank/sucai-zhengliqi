import AppKit
import Foundation
import Observation
import OrganizerCore
import UniformTypeIdentifiers

struct ScanProduct: Sendable {
    var plan: MovePlan
}

struct RunProduct: Sendable {
    var record: RunRecord?
    var runs: [RunRecord]
    var catalog: Catalog
    var state: LibraryState?
    var error: String?
}

@MainActor
@Observable
final class AppModel {
    var preferences: AppPreferences
    var libraryState: LibraryState
    var plan: MovePlan?
    var catalog: Catalog
    var runs: [RunRecord]
    var section: WorkspaceSection = .scan
    var isBusy = false
    var status = "还没有扫描"
    var lastError: String?
    var selectedIDs: Set<String> = []
    var pendingPaths: [String] = []
    var hotkey: HotkeyPreference
    var installID: String
    var keychainNote: String
    var filter: PreviewFilter = .movable
    var query = ""
    var confirming = false
    var capturingHotkey = false
    var desk: DeskConfig
    var listings: PublishedLibrary
    var searchOpen = false
    var searchQuery = ""
    var searchHits: [ArchiveRecord] = []
    var weeklyMarkdown = ""
    var spaceSummary = ""
    var staleVideos: [ArchiveRecord] = []
    var oauthCode = ""
    var oauthNote = "平台令牌只放钥匙串。没有令牌时可以导入 CSV 或 JSON。"
    var platformBusy = false
    var platformProgress = ""

    let homeDirectory: String
    @ObservationIgnored private var platformTask: Task<Void, Never>?
    @ObservationIgnored private var platformGeneration = 0
    private var debouncer = WatchDebouncer(window: 0.8)
    private let store = LocalFileStore()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        homeDirectory = home
        let loadedPreferences = (try? PreferencesStore.load(home: home, store: LocalFileStore())) ?? .fresh()
        preferences = loadedPreferences
        if loadedPreferences.libraryRoot.isEmpty {
            libraryState = .fresh()
            catalog = .empty()
            runs = []
            pendingPaths = []
        } else {
            let loadedState = (try? StateStore.load(library: loadedPreferences.libraryRoot, store: LocalFileStore())) ?? .fresh()
            libraryState = loadedState.applying(loadedPreferences)
            catalog = (try? IndexStore.load(library: loadedPreferences.libraryRoot, store: LocalFileStore())) ?? .empty()
            runs = (try? RunArchive.loadAll(library: loadedPreferences.libraryRoot, store: LocalFileStore())) ?? []
            pendingPaths = (try? PendingStore.load(library: loadedPreferences.libraryRoot, store: LocalFileStore())) ?? []
        }
        let sealed = Self.loadSealed(home: home)
        hotkey = sealed.preferences.hotkey
        installID = sealed.preferences.installID
        keychainNote = sealed.note
        desk = (try? DeskStore.load(home: home, store: LocalFileStore())) ?? .standard()
        listings = (try? PublishedStore.load(home: home, store: LocalFileStore())) ?? .empty()
        refreshMenu()
        refreshReports()
    }

    var needsOnboarding: Bool {
        !desk.onboardingDone || preferences.libraryRoot.isEmpty || preferences.scanRoots.isEmpty
    }

    var filteredItems: [PlannedMove] {
        guard let plan else { return [] }
        switch filter {
        case .movable: return plan.proposed
        case .optional: return plan.optionalItems
        case .blocked: return plan.blocked
        case .all: return plan.items
        }
    }

    var selectedBytes: Int64 {
        guard let plan else { return 0 }
        return plan.items.filter { selectedIDs.contains($0.id) && $0.disposition != .blocked }.reduce(0) { $0 + $1.bytes }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    func addRoot(_ path: String) {
        let normalized = PathKey.normalize(path)
        guard !preferences.scanRoots.contains(normalized) else { return }
        preferences.scanRoots.append(normalized)
        savePreferences()
    }

    func removeRoot(_ path: String) {
        preferences.scanRoots.removeAll { $0 == path }
        savePreferences()
    }

    func chooseLibrary() {
        guard let path = FolderPicker.choose(prompt: "设为产物库") else { return }
        preferences.libraryRoot = path
        reloadLibrary()
        savePreferences()
    }

    func chooseRoot() {
        guard let path = FolderPicker.choose(prompt: "添加扫描位置") else { return }
        addRoot(path)
    }

    func addStandardFolder(_ directory: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return }
        addRoot(url.path)
    }

    func beginScan() {
        guard !isBusy else { return }
        guard !preferences.libraryRoot.isEmpty else {
            lastError = OrganizerError.missingLibrary.description
            return
        }
        guard !preferences.scanRoots.isEmpty else {
            lastError = "先添加一个扫描位置。"
            return
        }
        isBusy = true
        status = "正在扫描…"
        let prefs = preferences
        let state = libraryState.applying(preferences)
        let desk = desk
        let listings = listings.videos
        let ai = localClassifier()
        Task {
            let product = await Task.detached(priority: .userInitiated) {
                let organizer = Organizer(store: LocalFileStore())
                var plan = organizer.scanAndPlan(preferences: prefs, state: state, desk: desk, listings: listings, localAI: ai)
                let videos = plan.items.filter { $0.kind == .video }.prefix(40).map(\.sourcePath)
                if !videos.isEmpty {
                    let hashes = await VideoFingerprints.collect(Array(videos))
                    if !hashes.isEmpty {
                        plan = organizer.scanAndPlan(preferences: prefs, state: state, desk: desk, listings: listings, frameHashes: hashes, localAI: ai)
                    }
                }
                return ScanProduct(plan: plan)
            }.value
            self.plan = product.plan
            self.selectedIDs = product.plan.preselectedIDs
            self.libraryState = state
            self.isBusy = false
            self.status = "可移动 \(product.plan.proposed.count) 个，另有 \(product.plan.optionalItems.count) 个待确认"
            self.section = .preview
            self.filter = product.plan.proposed.isEmpty ? .all : .movable
            self.refreshMenu()
            self.refreshReports()
        }
    }

    func previewPending() {
        guard !pendingPaths.isEmpty else { return }
        isBusy = true
        let paths = pendingPaths
        let prefs = preferences
        let state = libraryState.applying(preferences)
        let desk = desk
        let listings = listings.videos
        let ai = localClassifier()
        Task {
            let product = await Task.detached(priority: .userInitiated) {
                ScanProduct(plan: Organizer(store: LocalFileStore()).planSpecificFiles(paths: paths, preferences: prefs, state: state, desk: desk, listings: listings, localAI: ai))
            }.value
            self.plan = product.plan
            self.selectedIDs = product.plan.preselectedIDs
            self.pendingPaths = []
            self.isBusy = false
            self.section = .preview
            self.status = "监视到的新文件已放进预览。确认前不会移动。"
            if !prefs.libraryRoot.isEmpty {
                let library = prefs.libraryRoot
                Task.detached {
                    try? PendingStore.save(paths: [], library: library, store: LocalFileStore())
                }
            }
        }
    }

    func askToCommit() {
        guard plan != nil else { return }
        let movable = selectedIDs.intersection(Set((plan?.items ?? []).filter { $0.disposition != .blocked }.map(\.id)))
        if (plan?.proposed.count ?? 0) + (plan?.optionalItems.count ?? 0) > 0 && movable.isEmpty {
            lastError = "先勾选要处理的文件。"
            return
        }
        confirming = true
    }

    func commit() {
        guard let plan else { return }
        confirming = false
        isBusy = true
        status = libraryState.hasCompletedDryRun ? "正在移动…" : "正在演练…"
        let request = ExecuteRequest.make(
            confirmed: true,
            planFingerprint: plan.fingerprint,
            selectedIDs: selectedIDs,
            intendToApply: true,
            moveOnly: desk.moveOnly
        )
        let state = libraryState
        let library = plan.libraryRoot
        Task {
            let product = await Task.detached(priority: .userInitiated) { () -> RunProduct in
                let store = LocalFileStore()
                let organizer = Organizer(store: store)
                do {
                    var mutable = state
                    let record = try organizer.execute(plan: plan, request: request, state: &mutable)
                    return RunProduct(
                        record: record,
                        runs: (try? RunArchive.loadAll(library: library, store: store)) ?? [],
                        catalog: (try? IndexStore.load(library: library, store: store)) ?? .empty(),
                        state: (try? StateStore.load(library: library, store: store)) ?? mutable,
                        error: nil
                    )
                } catch {
                    return RunProduct(record: nil, runs: [], catalog: .empty(), state: nil, error: String(describing: error))
                }
            }.value
            self.isBusy = false
            if let error = product.error {
                self.lastError = error
                self.status = "没有完成"
                return
            }
            if let state = product.state { self.libraryState = state }
            self.runs = product.runs
            self.catalog = product.catalog
            self.status = product.record?.note ?? "完成"
            self.section = .runs
            self.refreshMenu()
            self.refreshReports()
        }
    }

    func undo(_ record: RunRecord) {
        guard !isBusy else { return }
        isBusy = true
        let library = record.libraryRoot
        let runID = record.id
        Task {
            let product = await Task.detached(priority: .userInitiated) { () -> RunProduct in
                let store = LocalFileStore()
                do {
                    let undone = try Organizer(store: store).undo(runID: runID, library: library)
                    return RunProduct(
                        record: undone,
                        runs: (try? RunArchive.loadAll(library: library, store: store)) ?? [],
                        catalog: (try? IndexStore.load(library: library, store: store)) ?? .empty(),
                        state: try? StateStore.load(library: library, store: store),
                        error: nil
                    )
                } catch {
                    return RunProduct(record: nil, runs: [], catalog: .empty(), state: nil, error: String(describing: error))
                }
            }.value
            self.isBusy = false
            if let error = product.error {
                self.lastError = error
                return
            }
            self.runs = product.runs
            self.catalog = product.catalog
            self.status = product.record?.note ?? "已撤销"
        }
    }

    func reloadIndex() {
        guard !preferences.libraryRoot.isEmpty else { return }
        let library = preferences.libraryRoot
        Task {
            let catalog = await Task.detached {
                (try? IndexStore.load(library: library, store: LocalFileStore())) ?? .empty()
            }.value
            self.catalog = catalog
        }
    }

    func exportCSV() {
        let text = IndexStore.csv(catalog)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "产物索引.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "已导出索引"
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func savePreferences() {
        preferences.minimumConfidence = min(max(preferences.minimumConfidence, 0.5), 0.95)
        preferences.maxDepth = min(max(preferences.maxDepth, 0), 32)
        libraryState = libraryState.applying(preferences)
        let prefs = preferences
        let state = libraryState
        let home = homeDirectory
        let library = prefs.libraryRoot
        let config = desk
        Task.detached {
            let store = LocalFileStore()
            try? PreferencesStore.save(prefs, home: home, store: store)
            try? DeskStore.save(config, home: home, store: store)
            if !library.isEmpty {
                try? StateStore.save(state, library: library, store: store)
            }
        }
        syncWatcher()
        refreshMenu()
    }

    func requireRehearsalAgain() {
        libraryState.hasCompletedDryRun = false
        savePreferences()
        status = "下一个产物库运行会重新演练"
    }

    func addRule(keyword: String, source: SourceTool) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            lastError = "规则关键词至少两个字。"
            return
        }
        preferences.userRules.append(UserRule.make(keyword: trimmed, source: source))
        savePreferences()
    }

    func removeRule(_ id: String) {
        preferences.userRules.removeAll { $0.id == id }
        savePreferences()
    }

    func applyHotkey(keyCode: UInt32, modifiers: UInt32, display: String) {
        hotkey = HotkeyPreference.make(keyCode: keyCode, carbonModifiers: modifiers, display: display)
        HotkeyCenter.shared.register(hotkey)
        let sealed = SealedPreferences.makeNew(installID: installID, hotkey: hotkey)
        guard let data = try? sealed.encoded() else { return }
        // 快捷键和安装标识不是机密，只存 ~/.chanwu/sealed，不碰钥匙串。
        // 钥匙串只在保存平台凭据时使用，避免启动或改快捷键时弹出钥匙串密码框。
        let store = FileSecureStore(directory: StorePaths.sealedDirectory(home: homeDirectory), files: LocalFileStore())
        do {
            try store.write(account: "sealed", data: data)
            keychainNote = "快捷键已存在 ~/.chanwu/sealed"
        } catch {
            keychainNote = "快捷键没有保存：\(error)"
        }
    }

    func syncWatcher() {
        if preferences.watchEnabled && !preferences.scanRoots.isEmpty {
            FolderWatcher.shared.start(paths: preferences.scanRoots)
        } else {
            FolderWatcher.shared.stop()
        }
    }

    func pollWatcher() {
        let paths = FolderWatcher.shared.drain()
        let now = Date()
        for path in paths {
            let size = (try? store.metadata(path).bytes) ?? -1
            debouncer.observe(path: path, size: size, at: now)
        }
        let ready = debouncer.settled(now: now)
        guard !ready.isEmpty else { return }
        pendingPaths = PendingQueue.add(paths: ready, existing: pendingPaths)
        refreshMenu()
        let library = preferences.libraryRoot
        let pending = pendingPaths
        guard !library.isEmpty else { return }
        Task.detached {
            try? PendingStore.save(paths: pending, library: library, store: LocalFileStore())
        }
    }

    func searchedEntries() -> [IndexEntry] {
        IndexStore.search(catalog, query: query)
    }

    private func reloadLibrary() {
        guard !preferences.libraryRoot.isEmpty else { return }
        libraryState = ((try? StateStore.load(library: preferences.libraryRoot, store: store)) ?? .fresh()).applying(preferences)
        catalog = (try? IndexStore.load(library: preferences.libraryRoot, store: store)) ?? .empty()
        runs = (try? RunArchive.loadAll(library: preferences.libraryRoot, store: store)) ?? []
        pendingPaths = (try? PendingStore.load(library: preferences.libraryRoot, store: store)) ?? []
    }

    func acceptDesktop() {
        if preferences.libraryRoot.isEmpty {
            preferences.libraryRoot = DefaultLocations.desktop(home: homeDirectory)
        }
        if preferences.scanRoots.isEmpty {
            preferences.scanRoots = DefaultLocations.scanRoots(home: homeDirectory)
        }
        preferences.watchEnabled = true
        desk.onboardingDone = true
        reloadLibrary()
        savePreferences()
    }

    func presentSearch() {
        searchOpen = true
        showWindow()
        runSearch()
    }

    func runSearch() {
        let query = searchQuery
        let library = preferences.libraryRoot
        let catalog = catalog
        let hits = ArchiveDatabase.open(path: StorePaths.sqliteFile(library))?.search(query) ?? []
        if hits.isEmpty {
            searchHits = IndexStore.search(catalog, query: query).map { entry in
                ArchiveRecord(
                    id: entry.id,
                    fileName: entry.fileName,
                    originalName: entry.meta?.originalName ?? entry.fileName,
                    kind: entry.kind.rawValue,
                    projectTag: entry.meta?.projectTag ?? "",
                    modifiedAt: "",
                    platform: entry.meta?.platform ?? "",
                    publishStatus: entry.meta?.publishStatus ?? "",
                    version: entry.meta?.versionLabel ?? "",
                    path: PathKey.joining(library, entry.relativePath),
                    contentClass: entry.meta?.contentClass ?? "",
                    publishedAt: "",
                    bytes: entry.bytes,
                    reason: entry.evidence.joined(separator: "；")
                )
            }
        } else {
            searchHits = hits
        }
    }

    func undoLast() {
        guard let target = runs.first(where: { item in
            item.mode == .applied && item.operations.contains { $0.action == .moved } && !runs.contains { $0.undoOfRunID == item.id }
        }) else {
            lastError = "没有可以撤回的移动。"
            return
        }
        undo(target)
    }

    func refreshReports() {
        let records = searchAll()
        let files = records.map { record in
            ReportFile(
                path: record.path,
                bytes: record.bytes,
                modifiedAt: ISO8601DateFormatter().date(from: record.modifiedAt) ?? Date(),
                indexedAt: ISO8601DateFormatter().date(from: record.modifiedAt),
                contentClass: record.contentClass,
                publishStatus: record.publishStatus,
                inHistory: record.path.contains("历史版本")
            )
        }
        let digest = WeeklyReports.digest(files, now: Date())
        weeklyMarkdown = digest.markdown
        let space = WeeklyReports.space(files)
        spaceSummary = "最大 \(space.largest.count) 个，可收回约 \(ByteFormat.string(bytes: space.reclaimableBytes))（渲染帧、历史版本、缓存、日志）。不会自动删除。"
        staleVideos = records.filter {
            PublishReminder.isStale(status: $0.publishStatus, since: ISO8601DateFormatter().date(from: $0.modifiedAt) ?? Date(), now: Date(), days: desk.pendingVideoDays)
        }
        if ReportSchedule.isSunday(Date()) && !preferences.libraryRoot.isEmpty {
            let desktop = DefaultLocations.desktop(home: homeDirectory)
            let name = ReportSchedule.fileName(Date())
            let path = PathKey.joining(DefaultLocations.reportDirectory(desktop: desktop), name)
            if !store.exists(path) {
                _ = try? WeeklyReports.write(digest, desktop: desktop, now: Date(), store: store)
            }
        }
    }

    func writeWeeklyReport() {
        let records = searchAll()
        let files = records.map { record in
            ReportFile(path: record.path, bytes: record.bytes, modifiedAt: ISO8601DateFormatter().date(from: record.modifiedAt) ?? Date(), indexedAt: Date(), contentClass: record.contentClass, publishStatus: record.publishStatus, inHistory: record.path.contains("历史版本"))
        }
        let digest = WeeklyReports.digest(files, now: Date())
        weeklyMarkdown = digest.markdown
        do {
            let path = try WeeklyReports.write(digest, desktop: DefaultLocations.desktop(home: homeDirectory), now: Date(), store: store)
            status = "周报已写入 \(path)"
        } catch {
            lastError = "周报没有写成：\(error)"
        }
    }

    func importPublished(text: String, platform: PublishPlatform) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: [PublishedVideo]
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            parsed = PublishImport.json(Data(trimmed.utf8), defaultPlatform: platform)
        } else {
            parsed = PublishImport.csv(trimmed, defaultPlatform: platform)
        }
        guard !parsed.isEmpty else {
            lastError = "没有从这段文字里读出已发布视频。"
            return
        }
        listings.videos.removeAll { video in parsed.contains { $0.platform == video.platform && $0.id == video.id } }
        listings.videos.append(contentsOf: parsed)
        let library = listings
        let home = homeDirectory
        Task.detached {
            try? PublishedStore.save(library, home: home, store: LocalFileStore())
        }
        status = "已导入 \(parsed.count) 条发布记录"
    }

    func authorize(_ platform: PublishPlatform) {
        let clientID = clientID(for: platform)
        guard !clientID.isEmpty else {
            lastError = "先在设置里填写 \(platform.displayName) 的 Client ID。"
            return
        }
        let url = OAuthEndpoints.authorizeURL(platform: platform, clientID: clientID, redirect: "http://127.0.0.1:8765/callback", state: installID)
        NSWorkspace.shared.open(URL(string: url)!)
        oauthNote = "浏览器打开后，把地址栏里的 code 贴回来。令牌只进钥匙串。"
    }

    func exchangeCode(_ platform: PublishPlatform) {
        let code = oauthCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        let clientID = clientID(for: platform)
        let secretText = keychainString(secretAccount(platform)) ?? ""
        guard !clientID.isEmpty, !secretText.isEmpty else {
            lastError = "换令牌需要 Client ID 和 Client Secret。"
            return
        }
        let form = OAuthEndpoints.tokenForm(platform: platform, code: code, clientID: clientID, clientSecret: secretText, redirect: "http://127.0.0.1:8765/callback")
        let url = OAuthEndpoints.tokenURL(platform: platform)
        let account = tokenAccount(platform)
        let generation = startPlatformWork("正在向 \(platform.displayName) 换取令牌…")
        platformTask = Task { @MainActor in
            let token = await PlatformClient.post(url: url, body: Data(form.utf8), timeout: 20).flatMap(PublishResponseParser.accessToken)
            guard !Task.isCancelled, self.platformGeneration == generation else { return }
            guard let token else {
                self.lastError = "没有换到访问令牌。确认 code 还没过期。"
                self.oauthNote = "换令牌没有完成。"
                self.finishPlatformWork(generation)
                return
            }
            try? KeychainStore().write(account: account, data: Data(token.utf8))
            self.oauthCode = ""
            self.oauthNote = "\(platform.displayName) 的令牌已放进钥匙串。"
            self.finishPlatformWork(generation)
        }
    }

    func syncPlatform(_ platform: PublishPlatform) {
        guard let token = keychainString(tokenAccount(platform)) else {
            lastError = "钥匙串里还没有 \(platform.displayName) 的令牌。可以改用 CSV。"
            return
        }
        let url = OAuthEndpoints.listingsURL(platform: platform)
        let generation = startPlatformWork("正在连接 \(platform.displayName)…")
        platformTask = Task { @MainActor in
            self.platformProgress = "正在读取 \(platform.displayName) 的发布列表…"
            self.oauthNote = self.platformProgress
            let data = await PlatformClient.get(url: url, token: token)
            guard !Task.isCancelled, self.platformGeneration == generation else { return }
            guard let data else {
                self.lastError = "没有拉到 \(platform.displayName) 的列表。"
                self.oauthNote = "同步没有完成。可以改用 CSV。"
                self.finishPlatformWork(generation)
                return
            }
            let videos: [PublishedVideo]
            switch platform {
            case .youtube: videos = PublishResponseParser.youtube(data)
            case .tiktok: videos = PublishResponseParser.tiktok(data)
            case .facebook: videos = PublishResponseParser.facebook(data)
            }
            guard !Task.isCancelled, self.platformGeneration == generation else { return }
            guard !videos.isEmpty else {
                self.lastError = "\(platform.displayName) 返回了空列表，或令牌权限不够。"
                self.oauthNote = "同步没有完成。可以改用 CSV。"
                self.finishPlatformWork(generation)
                return
            }
            self.listings.videos.removeAll { $0.platform == platform }
            self.listings.videos.append(contentsOf: videos)
            let library = self.listings
            let home = self.homeDirectory
            Task.detached { try? PublishedStore.save(library, home: home, store: LocalFileStore()) }
            self.status = "已同步 \(videos.count) 条 \(platform.displayName) 发布记录"
            self.oauthNote = self.status
            self.finishPlatformWork(generation)
        }
    }

    func cancelPlatformSync() {
        platformGeneration += 1
        platformTask?.cancel()
        platformTask = nil
        platformBusy = false
        platformProgress = ""
        oauthNote = "已取消平台同步。"
    }

    private func startPlatformWork(_ note: String) -> Int {
        platformTask?.cancel()
        platformGeneration += 1
        platformBusy = true
        platformProgress = note
        oauthNote = note
        return platformGeneration
    }

    private func finishPlatformWork(_ generation: Int) {
        guard platformGeneration == generation else { return }
        platformBusy = false
        platformProgress = ""
        platformTask = nil
    }

    /// 钥匙串没有这条，或用户拒绝授权时，都当作没有令牌。
    private func keychainString(_ account: String) -> String? {
        let loaded = (try? KeychainStore().read(account: account)) ?? nil
        guard let data = loaded, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveClientSecret(_ platform: PublishPlatform, secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? KeychainStore().write(account: secretAccount(platform), data: Data(trimmed.utf8))
        oauthNote = "\(platform.displayName) 的 Client Secret 已放进钥匙串，不会写进 JSON。"
    }

    func makeDelivery(tag: String) {
        let matches = searchAll().filter { $0.projectTag == tag && !$0.path.contains("历史版本") }
        guard !matches.isEmpty else {
            lastError = "这个项目标签下没有可打包的归档文件。"
            return
        }
        var files: [(relativePath: String, data: Data)] = []
        for record in matches {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: record.path)) else { continue }
            files.append((record.fileName, data))
        }
        guard !files.isEmpty else { return }
        let packed = DeliveryPack.make(project: tag, files: files, now: Date())
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(tag)-交付.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try packed.zip.write(to: url)
            status = "已写出 \(files.count) 个文件和 SHA256 清单"
        } catch {
            lastError = "打包失败：\(error.localizedDescription)"
        }
    }

    func addRoute(name: String, extensions: String, path: String, slot: DeskSlot) {
        desk.rules.append(RouteRule.make(nameContains: name, extensions: extensions.split(separator: ",").map { String($0) }, pathUnder: path, slot: slot))
        savePreferences()
    }

    func removeRoute(_ id: String) {
        desk.rules.removeAll { $0.id == id }
        savePreferences()
    }

    func moveRoute(_ id: String, up: Bool) {
        guard let index = desk.rules.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard desk.rules.indices.contains(target) else { return }
        desk.rules.swapAt(index, target)
        savePreferences()
    }

    func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !desk.extraTags.contains(trimmed) else { return }
        desk.extraTags.append(trimmed)
        savePreferences()
    }

    func refreshMenu() {
        let pending = pendingPaths.count + (plan?.proposed.count ?? 0)
        let today = todayArchivedCount()
        StatusBarController.shared.refresh(pending: pending, today: today)
    }

    private func todayArchivedCount() -> Int {
        let calendar = Calendars.shanghai()
        return runs.filter { record in
            record.mode == .applied && calendar.isDate(record.finishedAt, inSameDayAs: Date())
        }.reduce(0) { $0 + $1.operations.filter { $0.action == .moved }.count }
    }

    private func searchAll() -> [ArchiveRecord] {
        ArchiveDatabase.open(path: StorePaths.sqliteFile(preferences.libraryRoot))?.search("") ?? []
    }

    private func localClassifier() -> any LocalClassifier {
        guard desk.localAIEnabled else { return DisabledLocalAI() }
        return OllamaClassifier(enabled: true, endpoint: desk.ollamaEndpoint, model: desk.ollamaModel, transport: SessionPoster())
    }

    private func clientID(for platform: PublishPlatform) -> String {
        switch platform {
        case .youtube: return desk.youtubeClientID
        case .tiktok: return desk.tiktokClientID
        case .facebook: return desk.facebookClientID
        }
    }

    private func tokenAccount(_ platform: PublishPlatform) -> String { "oauth.\(platform.rawValue).token" }
    private func secretAccount(_ platform: PublishPlatform) -> String { "oauth.\(platform.rawValue).secret" }

    private static func loadSealed(home: String) -> (preferences: SealedPreferences, note: String) {
        // 启动时不读写钥匙串：ad-hoc 签名每次重新打包都会变，读旧条目会弹出钥匙串密码框。
        let store = FileSecureStore(directory: StorePaths.sealedDirectory(home: home), files: LocalFileStore())
        if let data = try? store.read(account: "sealed"), let sealed = try? SealedPreferences.decode(data) {
            return (sealed, "快捷键从 ~/.chanwu/sealed 读取")
        }
        let created = SealedPreferences.makeNew()
        if let data = try? created.encoded(), (try? store.write(account: "sealed", data: data)) != nil {
            return (created, "已在 ~/.chanwu/sealed 建立这台 Mac 的安装标识")
        }
        return (created, "使用默认快捷键 ⌥⌘O")
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case scan
    case preview
    case index
    case runs
    case reports
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "扫描"
        case .preview: return "预览"
        case .index: return "索引"
        case .runs: return "记录"
        case .reports: return "报告"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .scan: return "magnifyingglass"
        case .preview: return "checklist"
        case .index: return "square.stack.3d.up"
        case .runs: return "clock.arrow.circlepath"
        case .reports: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

enum PreviewFilter: String, CaseIterable, Identifiable {
    case movable
    case optional
    case blocked
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movable: return "可移动"
        case .optional: return "待确认"
        case .blocked: return "已拦住"
        case .all: return "全部"
        }
    }
}
