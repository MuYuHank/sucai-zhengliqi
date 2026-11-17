import AppKit
import Foundation
import Observation
import OrganizerCore
import ServiceManagement
import UniformTypeIdentifiers

struct MoveBanner: Equatable, Identifiable {
    var id: String
    var record: RunRecord
    var moved: Int
    var copied: Int
    var skippedVolume: Int
    var failed: Int
    var dry: Bool
}

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
    var section: WorkspaceSection = .preview
    private var pageNotes = PageNotes(values: [WorkspaceSection.preview.rawValue: "还没有扫描"])
    var libraryCategory: String?
    var libraryUsesGrid = false
    var hiddenIDs: Set<String> = []
    var undoBanner: MoveBanner?
    var reportFiles: [ReportFile] = []
    var weeklyDigest: WeeklyDigest?
    var spaceReport = SpaceReport(largest: [], reclaimable: [], reclaimableBytes: 0)
    var platformLinked: [String: Bool] = [:]
    var platformSecretSaved: [String: Bool] = [:]
    var platformSyncedAt: [String: Date] = [:]
    var quickLookURL: URL?
    var isBusy = false
    var status: String { pageNotes.text(for: section.rawValue) }

    func setStatus(_ text: String, page: WorkspaceSection) {
        pageNotes.set(text, page: page.rawValue)
    }
    var lastError: String?
    var selectedIDs: Set<String> = []
    var pendingPaths: [String] = []
    var hotkey: HotkeyPreference
    var installID: String
    var keychainNote: String
    var filter: PreviewFilter = .movable
    var query = ""
    var previewQuery = ""
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
    var oauthNote = ""
    var platformBusy = false
    var platformProgress = ""
    var distribution: DistributionConfig
    var recognizing = false
    var recognitionNote = ""
    var dispatchNote = ""
    var recognitionQuote: RecognitionQuote?
    /// 费用确认只挂在发起它的那个窗口上。设置和主窗口同时开着时，不再各弹一次。
    var recognitionQuoteWindow: RecognitionQuoteWindow?
    var sendingID: String?
    /// 真正发送前的确认。演练不走这里。
    var confirmingSendID: String?
    var sessionRecipients: [KnownRecipient] = []
    var sessionNote = ""
    var loadingRecipients = false

    let homeDirectory: String
    @ObservationIgnored private var quotedJobs: [RecognitionJob] = []
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
        distribution = (try? DistributionStore.load(home: home, store: LocalFileStore())) ?? .standard()
        refreshMenu()
        refreshReports()
    }

    var needsOnboarding: Bool {
        !desk.onboardingDone || preferences.libraryRoot.isEmpty || preferences.scanRoots.isEmpty
    }

    var filteredItems: [PlannedMove] {
        var items = visibleItems
        switch filter {
        case .movable: items = items.filter { $0.disposition == .proposed }
        case .optional: items = items.filter { $0.disposition == .optional }
        case .blocked: items = items.filter { $0.disposition == .blocked }
        case .all: break
        }
        let needle = previewQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            item.fileName.localizedCaseInsensitiveContains(needle)
                || item.sourcePath.localizedCaseInsensitiveContains(needle)
                || item.destinationPath.localizedCaseInsensitiveContains(needle)
                || (item.meta?.originalName.localizedCaseInsensitiveContains(needle) ?? false)
                || (item.meta?.projectTag.localizedCaseInsensitiveContains(needle) ?? false)
                || item.reason.localizedCaseInsensitiveContains(needle)
        }
    }

    var pendingCount: Int { pendingPaths.count }

    var todayArchived: Int { RunStats.movedToday(runs: runs, now: Date()).count }

    var todayArchivedBytes: Int64 { RunStats.movedToday(runs: runs, now: Date()).bytes }

    func previewCount(_ filter: PreviewFilter) -> Int {
        switch filter {
        case .movable: return visibleItems.filter { $0.disposition == .proposed }.count
        case .optional: return visibleItems.filter { $0.disposition == .optional }.count
        case .blocked: return visibleItems.filter { $0.disposition == .blocked }.count
        case .all: return visibleItems.count
        }
    }

    var visibleItems: [PlannedMove] {
        guard let plan else { return [] }
        return plan.items.filter { !hiddenIDs.contains($0.id) }
    }

    var movableSelected: [PlannedMove] {
        visibleItems.filter { selectedIDs.contains($0.id) && $0.disposition != .blocked }
    }

    var selectedBytes: Int64 {
        movableSelected.reduce(0) { $0 + $1.bytes }
    }

    var selectedDeleteCount: Int {
        movableSelected.filter { slot(of: $0) == .pendingDelete }.count
    }

    var undoCandidate: RunRecord? {
        runs.first { item in
            item.mode == .applied
                && item.operations.contains { $0.action == .moved || $0.action == .copiedSourceRetained }
                && !runs.contains { $0.undoOfRunID == item.id }
        }
    }

    var crossVolumeSelectedCount: Int {
        movableSelected.filter { !store.sameVolume($0.sourcePath, $0.destinationPath) }.count
    }

    var confirmMessage: String {
        let count = movableSelected.count
        let bytes = ByteFormat.string(bytes: selectedBytes)
        var clauses: [String] = []
        if !libraryState.hasCompletedDryRun {
            clauses.append("第一次运行只写记录，不移动任何文件。勾选了 \(count) 个，大约 \(bytes)。")
            if selectedDeleteCount > 0 {
                clauses.append("其中 \(selectedDeleteCount) 个放进「待删」（只是归档）。")
            }
            clauses.append("演练完成后再确认一次，才会真正移动。")
            return clauses.joined()
        }
        clauses.append("共 \(bytes)。")
        if selectedDeleteCount > 0 {
            clauses.append("其中 \(selectedDeleteCount) 个放进「待删」（只是归档）。")
        }
        let otherDisk = crossVolumeSelectedCount
        if desk.moveOnly {
            if otherDisk > 0 {
                clauses.append("在其他磁盘上的 \(otherDisk) 个文件会留在原处，不会复制。")
            }
        } else if otherDisk > 0 {
            clauses.append("其他磁盘上的 \(otherDisk) 个文件只复制，源文件仍留在原地。撤销可以移回同一块磁盘上的文件，不会删除副本。")
        }
        clauses.append("移动后可以按 ⌘Z 撤销。")
        return clauses.joined()
    }

    var lastErrorSuggestsPrivacy: Bool {
        guard let lastError else { return false }
        return lastError.contains("权限") || lastError.contains("无法读取") || lastError.contains("不允许") || lastError.contains("Operation not permitted")
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
        guard let path = FolderPicker.choose(prompt: "设为素材库") else { return }
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
        setStatus("正在扫描…", page: .preview)
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
            self.hiddenIDs = []
            self.undoBanner = nil
            self.libraryState = state
            self.isBusy = false
            self.setStatus("可移动 \(product.plan.proposed.count) 个，另有 \(product.plan.optionalItems.count) 个待确认", page: .preview)
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
            self.hiddenIDs = []
            self.undoBanner = nil
            self.pendingPaths = []
            self.isBusy = false
            self.section = .preview
            self.setStatus("新文件已放进待整理。确认前不会移动。", page: .preview)
            if !prefs.libraryRoot.isEmpty {
                let library = prefs.libraryRoot
                Task.detached {
                    try? PendingStore.save(paths: [], library: library, store: LocalFileStore())
                }
            }
        }
    }

    func askToCommit() {
        guard plan != nil, !movableSelected.isEmpty else { return }
        confirming = true
    }

    func commit() {
        guard let plan else { return }
        confirming = false
        isBusy = true
        setStatus(libraryState.hasCompletedDryRun ? "正在移动…" : "正在演练…", page: .preview)
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
                self.setStatus("没有完成", page: .preview)
                return
            }
            if let state = product.state { self.libraryState = state }
            self.runs = product.runs
            self.catalog = product.catalog
            if let record = product.record {
                let moved = record.operations.filter { $0.action == .moved }.count
                let copied = record.operations.filter { $0.action == .copiedSourceRetained }.count
                let skippedVolume = record.operations.filter { $0.action == .skipped && ($0.reason.contains("跨卷") || $0.reason.contains("其他磁盘")) }.count
                let failed = record.operations.filter { $0.action == .failed }.count
                self.undoBanner = MoveBanner(
                    id: record.id,
                    record: record,
                    moved: moved,
                    copied: copied,
                    skippedVolume: skippedVolume,
                    failed: failed,
                    dry: record.mode != .applied
                )
                if record.mode == .applied {
                    let gone = Set(record.operations.filter { $0.action == .moved || $0.action == .copiedSourceRetained }.map(\.id))
                    self.hiddenIDs.formUnion(gone)
                    self.selectedIDs.subtract(gone)
                }
            }
            if let record = product.record, record.mode == .applied {
                self.recognizeApplied(record)
            }
            self.setStatus(product.record?.note ?? "完成", page: .preview)
            self.refreshMenu()
            self.refreshReports()
        }
    }

    func undo(_ record: RunRecord) {
        guard !isBusy else { return }
        isBusy = true
        let page = section
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
            if let record = product.record {
                let restored = Set(record.operations.map { operation -> String in
                    operation.id.hasSuffix("-undo") ? String(operation.id.dropLast("-undo".count)) : operation.id
                })
                self.hiddenIDs.subtract(restored)
            }
            let note = product.record?.note ?? "已撤销"
            self.pageNotes = self.pageNotes.afterUndo(preview: WorkspaceSection.preview.rawValue, note: note)
            if page != .preview {
                self.setStatus(note, page: page)
            }
            self.refreshReports()
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
        panel.nameFieldStringValue = "素材索引.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            setStatus("已导出索引", page: .library)
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func saveDistribution() {
        let config = distribution
        let home = homeDirectory
        try? DistributionStore.save(config, home: home, store: LocalFileStore())
    }

    func recognizeOutstanding(from window: RecognitionQuoteWindow) {
        guard distribution.enabled else {
            recognitionNote = "识别还关着。在设置里打开之后才会把文字发给本机的 OpenClaw。"
            return
        }
        guard !recognizing, recognitionQuote == nil else {
            recognitionNote = recognizing ? "上一次识别还没结束。" : "上一次的确认还开着。关掉那个窗口后再试。"
            return
        }
        guard RecognitionAgent.callingName(distribution.agent, acknowledged: distribution.allowMainAgent) != nil else {
            recognitionNote = RecognitionAgent.refusal
            return
        }
        let library = preferences.libraryRoot
        guard !library.isEmpty else {
            recognitionNote = "还没有素材库。"
            return
        }
        let agent = distribution.agent
        Task.detached {
            let records = ArchiveDatabase.open(path: StorePaths.sqliteFile(library))?.unrecognized() ?? []
            let chosen = RecognitionBatch.outstanding(records: records)
            let quote = RecognitionCost.quote(files: chosen.count, agent: agent, names: chosen.map(\.fileName))
            await MainActor.run {
                if chosen.isEmpty {
                    self.recognitionNote = "没有需要识别的文件。"
                    return
                }
                self.quotedJobs = []
                self.recognitionQuoteWindow = window
                self.recognitionQuote = quote
            }
        }
    }

    func runQuotedRecognition() {
        let jobs = quotedJobs
        recognitionQuote = nil
        recognitionQuoteWindow = nil
        quotedJobs = []
        if jobs.isEmpty {
            startLibraryRecognition()
        } else {
            runRecognition(jobs: jobs)
        }
    }

    func cancelRecognitionQuote() {
        recognitionQuote = nil
        recognitionQuoteWindow = nil
        quotedJobs = []
        recognitionNote = "这次没有识别。"
    }

    private func startLibraryRecognition() {
        guard !recognizing else { return }
        let library = preferences.libraryRoot
        guard !library.isEmpty else {
            recognitionNote = "还没有素材库。"
            return
        }
        recognizing = true
        recognitionNote = "正在找出还没识别的文件…"
        Task.detached {
            let records = ArchiveDatabase.open(path: StorePaths.sqliteFile(library))?.unrecognized() ?? []
            let jobs = RecognitionBatch.outstanding(records: records).map { record in
                RecognitionJob(
                    path: record.path,
                    fileName: record.fileName,
                    contentClass: record.contentClass,
                    kind: record.kind,
                    projectTag: record.projectTag,
                    tags: []
                )
            }
            await MainActor.run {
                self.recognizing = false
                if jobs.isEmpty {
                    self.recognitionNote = "没有需要识别的文件。"
                    return
                }
                self.runRecognition(jobs: jobs)
            }
        }
    }

    func recognizeApplied(_ record: RunRecord) {
        guard distribution.enabled else { return }
        guard RecognitionAgent.allowsAutomaticRun(distribution.agent) else {
            recognitionNote = "移动之后没有自动识别。main 或还没填写的代理不会自动运行。要识别的话，先填一个不带工具的代理，再点「识别未处理的文件」。"
            return
        }
        let planItems = plan?.items ?? []
        let jobs = record.operations.compactMap { operation -> RecognitionJob? in
            guard operation.action == .moved || operation.action == .copiedSourceRetained else { return nil }
            let item = planItems.first { $0.id == operation.id }
            let path = operation.destination
            let name = PathKey.name(path)
            let contentClass = item?.meta?.contentClass ?? ""
            guard RecognitionKind.accepts(name: name, path: path, contentClass: contentClass) else { return nil }
            return RecognitionJob(
                path: path,
                fileName: name,
                contentClass: contentClass,
                kind: item?.kind.rawValue ?? operation.kind.rawValue,
                projectTag: item?.meta?.projectTag ?? "",
                tags: []
            )
        }
        let batch = Array(jobs.prefix(RecognitionService.batchLimit))
        guard !batch.isEmpty else { return }
        if recognizing || recognitionQuote != nil {
            recognitionNote = "上一次识别还没结束。完成后可以再点「识别未处理的文件」。"
            return
        }
        quotedJobs = batch
        recognitionQuoteWindow = .main
        recognitionQuote = RecognitionCost.quote(files: batch.count, agent: distribution.agent, names: batch.map(\.fileName))
    }

    func runRecognition(jobs: [RecognitionJob]) {
        guard distribution.enabled, !recognizing, !jobs.isEmpty else { return }
        guard RecognitionAgent.callingName(distribution.agent, acknowledged: distribution.allowMainAgent) != nil else {
            recognitionNote = RecognitionAgent.refusal
            return
        }
        recognizing = true
        recognitionNote = "正在识别…"
        let config = distribution
        let home = homeDirectory
        let tags = ProjectTags.builtins + desk.extraTags
        let library = preferences.libraryRoot
        let minimumConfidence = preferences.minimumConfidence
        let batch = Array(jobs.prefix(RecognitionService.batchLimit))
        Task.detached {
            let files = batch.map { job in
                RecognitionWork(
                    path: job.path,
                    fileName: job.fileName,
                    contentClass: job.contentClass,
                    kind: job.kind,
                    projectTag: job.projectTag,
                    tags: job.tags,
                    text: MacTextExtractor.extract(path: job.path)
                )
            }
            let result = RecognitionBatch.run(
                enabled: true,
                files: files,
                allowedTags: tags,
                config: config,
                home: home,
                runner: ProcessOpenClaw(),
                now: Date(),
                minimumConfidence: minimumConfidence
            )
            if !library.isEmpty, let database = ArchiveDatabase.open(path: StorePaths.sqliteFile(library)) {
                for update in result.updates {
                    database.setRecognition(
                        path: update.path,
                        summary: update.summary,
                        project: update.project,
                        confidence: update.confidence,
                        recognizedAt: update.recognizedAt,
                        text: update.text
                    )
                }
            }
            let proposals = result.proposals
            let note = result.note
            await MainActor.run {
                var pending = self.distribution.pending
                DispatchBoard.enqueue(proposals, into: &pending)
                self.distribution.pending = pending
                self.recognizing = false
                self.recognitionNote = note
                self.saveDistribution()
            }
        }
    }

    func addDispatchRule(project: String, kind: String, tag: String, channel: String, account: String, target: String, alias: String = "", messageTemplate: String, attachFile: Bool) {
        let rule = DispatchRule.make(
            project: project,
            kind: kind,
            tag: tag,
            channel: channel.trimmingCharacters(in: .whitespacesAndNewlines),
            account: account.trimmingCharacters(in: .whitespacesAndNewlines),
            target: target.trimmingCharacters(in: .whitespacesAndNewlines),
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            messageTemplate: messageTemplate.isEmpty ? DistributionConfig.defaultMessageTemplate : messageTemplate,
            attachFile: attachFile
        )
        guard !rule.channel.isEmpty, !rule.target.isEmpty else { return }
        guard !rule.project.isEmpty || !rule.kind.isEmpty || !rule.tag.isEmpty else { return }
        distribution.rules.append(rule)
        saveDistribution()
    }

    func removeDispatchRule(_ id: String) {
        distribution.rules.removeAll { $0.id == id }
        saveDistribution()
    }

    func removePath(fromRule id: String) {
        guard let index = distribution.rules.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = DispatchTemplate.removingPathToken(distribution.rules[index].messageTemplate)
        distribution.rules[index].messageTemplate = cleaned
        let result = DispatchBoard.stripQueuedPaths(ruleID: id, template: cleaned, pending: &distribution.pending)
        var notes = ["已去掉这条规则里的路径。"]
        if result.rewritten > 0 {
            notes.append("重写了 \(result.rewritten) 条还没改过的待分发。")
        }
        if !result.editedFileNames.isEmpty {
            notes.append("\(result.editedFileNames.joined(separator: "、")) 的正文是你改过的，还留着本机路径。请到待分发里点编辑，自己删掉。")
        }
        dispatchNote = notes.joined()
        saveDistribution()
    }

    func updateDispatchMessage(id: String, message: String) {
        DispatchBoard.edit(id: id, message: message, pending: &distribution.pending)
        saveDistribution()
    }

    func updateDispatchProject(id: String, project: String) {
        guard let index = distribution.pending.firstIndex(where: { $0.id == id }) else { return }
        let current = distribution.pending[index]
        guard current.project != project else { return }
        let result = DispatchBoard.retarget(current, project: project, rules: distribution.rules)
        distribution.pending[index] = result.item
        var note = result.matched ? "已按「\(result.item.project)」重新匹配收件人。" : "没有规则能接住「\(result.item.project)」。收件人还是原来的。"
        if !result.manualBodyNote.isEmpty {
            note += result.manualBodyNote
        }
        dispatchNote = note
        saveDistribution()
    }

    func restoreSkipped(_ entry: DispatchLogEntry) {
        guard !entry.restored else { return }
        var pending = distribution.pending
        let restored = DispatchBoard.restore(entry, into: &pending)
        let alreadyQueued = entry.snapshot.map { snapshot in
            pending.contains { $0.path == snapshot.path && $0.ruleID == snapshot.ruleID }
        } ?? false
        distribution.pending = pending
        if restored || alreadyQueued {
            if let index = distribution.log.firstIndex(where: { $0.id == entry.id }) {
                distribution.log[index].restored = true
            }
            dispatchNote = restored ? "已放回待分发。" : "这条已经在待分发里。"
        } else {
            dispatchNote = "这条没有可放回的内容。"
        }
        saveDistribution()
    }

    func requestSend(id: String) {
        guard sendingID == nil else { return }
        guard let item = distribution.pending.first(where: { $0.id == id }) else { return }
        if DispatchMessageGuard.blocksSend(item.message) {
            dispatchNote = DispatchMessageGuard.warning
            return
        }
        if RehearsalBook.needsDryRun(channel: item.channel, account: item.account, target: item.target, rehearsed: distribution.rehearsedTargets) {
            sendDispatch(id: id, forceDryRun: true)
        } else {
            confirmingSendID = id
        }
    }

    func confirmPendingSend() {
        guard let id = confirmingSendID else { return }
        confirmingSendID = nil
        sendDispatch(id: id, forceDryRun: false)
    }

    func retryDispatch(_ entry: DispatchLogEntry) {
        guard entry.outcome == .failed else { return }
        guard !DispatchRetry.superseded(entry, log: distribution.log, sent: distribution.sentIndex) else { return }
        let itemID: String
        if distribution.pending.contains(where: { $0.id == entry.itemID }) {
            itemID = entry.itemID
        } else if let snapshot = entry.snapshot {
            var pending = distribution.pending
            if !pending.contains(where: { $0.path == snapshot.path && $0.ruleID == snapshot.ruleID }) {
                pending.append(snapshot)
                distribution.pending = pending
                saveDistribution()
            }
            itemID = snapshot.id
        } else {
            return
        }
        if DispatchRetry.forcesDryRun(entry) {
            sendDispatch(id: itemID, forceDryRun: true)
        } else {
            requestSend(id: itemID)
        }
    }

    func skipDispatch(id: String) {
        guard sendingID != id else { return }
        if let entry = DispatchBoard.skip(id: id, pending: &distribution.pending, now: Date()) {
            distribution.log.append(entry)
            trimDispatchLog()
            dispatchNote = entry.detail
            saveDistribution()
        }
    }

    func sendDispatch(id: String, forceDryRun: Bool) {
        guard sendingID == nil else { return }
        guard let item = distribution.pending.first(where: { $0.id == id }) else { return }
        if DispatchMessageGuard.blocksSend(item.message) {
            dispatchNote = DispatchMessageGuard.warning
            return
        }
        let dryRun = forceDryRun || RehearsalBook.needsDryRun(
            channel: item.channel,
            account: item.account,
            target: item.target,
            rehearsed: distribution.rehearsedTargets
        )
        sendingID = id
        let config = distribution
        let home = homeDirectory
        Task.detached {
            let result = DispatchSender.deliver(item: item, config: config, home: home, dryRun: dryRun, runner: ProcessOpenClaw())
            await MainActor.run {
                self.finishDispatch(id: id, ok: result.ok, dryRun: dryRun, detail: result.detail)
            }
        }
    }

    func refreshRecipients() {
        guard !loadingRecipients else { return }
        loadingRecipients = true
        sessionNote = "正在读取会话…"
        let config = distribution
        let home = homeDirectory
        Task.detached {
            let request = OpenClawCommands.sessions(
                executable: config.executable(home: home),
                agent: config.agent,
                timeoutSeconds: min(config.timeoutSeconds, 30),
                pathPrefixes: config.expandedPathPrefixes(home: home)
            )
            let parsed: [KnownRecipient]
            let note: String
            do {
                let response = try ProcessOpenClaw().run(request)
                if response.status == 0 {
                    parsed = SessionRecipients.parse(response.stdout)
                    note = parsed.isEmpty ? "这次没有读到收件人。可以自己填频道、账号和收件人。" : "读到 \(parsed.count) 个收件人。点一下才填进规则，不会自动保存。"
                } else {
                    parsed = []
                    note = "没有读到会话。可以自己填频道、账号和收件人。"
                }
            } catch {
                parsed = []
                note = "没有读到会话。可以自己填频道、账号和收件人。"
            }
            await MainActor.run {
                self.sessionRecipients = parsed
                self.sessionNote = note
                self.loadingRecipients = false
            }
        }
    }

    private func finishDispatch(id: String, ok: Bool, dryRun: Bool, detail: String) {
        sendingID = nil
        guard let item = distribution.pending.first(where: { $0.id == id }) else { return }
        var pending = distribution.pending
        var rehearsed = distribution.rehearsedTargets
        let entry = DispatchBoard.finishSend(
            item: item,
            ok: ok,
            dryRun: dryRun,
            detail: detail,
            pending: &pending,
            rehearsed: &rehearsed,
            now: Date()
        )
        distribution.pending = pending
        distribution.rehearsedTargets = rehearsed
        distribution.log.append(entry)
        if entry.outcome == .sent {
            SentIndex.remember(
                channel: entry.channel,
                account: entry.account,
                target: entry.target,
                path: entry.path,
                fileName: entry.fileName,
                at: entry.at,
                into: &distribution.sentIndex
            )
        }
        trimDispatchLog()
        dispatchNote = detail
        saveDistribution()
    }

    private func trimDispatchLog() {
        if distribution.log.count > 200 {
            distribution.log.removeFirst(distribution.log.count - 200)
        }
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
        setStatus("下一次确认会重新演练，不会马上移动文件。", page: .preview)
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

    func restoreRule(_ rule: UserRule, at index: Int) {
        let insertAt = min(max(index, 0), preferences.userRules.count)
        preferences.userRules.insert(rule, at: insertAt)
        savePreferences()
    }

    func moveUserRules(from offsets: IndexSet, to destination: Int) {
        preferences.userRules = Self.reordered(preferences.userRules, from: offsets, to: destination)
        savePreferences()
    }

    private static func reordered<T>(_ items: [T], from offsets: IndexSet, to destination: Int) -> [T] {
        var copy = items
        let moving = offsets.sorted().map { copy[$0] }
        for index in offsets.sorted(by: >) { copy.remove(at: index) }
        let shift = offsets.filter { $0 < destination }.count
        let index = min(max(destination - shift, 0), copy.count)
        copy.insert(contentsOf: moving, at: index)
        return copy
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
        guard !preferences.scanRoots.isEmpty else {
            lastError = "先选择扫描位置。不会自动加入未勾选的文件夹。"
            return
        }
        preferences.watchEnabled = true
        desk.onboardingDone = true
        reloadLibrary()
        savePreferences()
    }

    func presentSearch() {
        QuickSearchController.shared.toggle(model: self)
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
        let window = NSApp.keyWindow
        let responderManager = window?.firstResponder?.undoManager
        let windowManager = window?.undoManager
        let route = UndoRouting.undo(
            responderCanUndo: responderManager?.canUndo == true,
            windowCanUndo: windowManager?.canUndo == true,
            keyWindowIsMain: window?.identifier?.rawValue == OrganizerWindow.main
        )
        switch route {
        case .windowAction:
            if responderManager?.canUndo == true {
                responderManager?.undo()
            } else {
                windowManager?.undo()
            }
        case .fileMove:
            undoLatestMove()
        case .none:
            break
        }
    }

    func undoLatestMove() {
        guard !isBusy, let target = undoCandidate else { return }
        undo(target)
    }

    func redoLast() {
        let window = NSApp.keyWindow
        let responderManager = window?.firstResponder?.undoManager
        let windowManager = window?.undoManager
        let route = UndoRouting.redo(
            responderCanRedo: responderManager?.canRedo == true,
            windowCanRedo: windowManager?.canRedo == true
        )
        guard route == .windowAction else { return }
        if responderManager?.canRedo == true {
            responderManager?.redo()
        } else {
            windowManager?.redo()
        }
    }

    func refreshReports() {
        let records = searchAll()
        let files = currentReportFiles()
        let digest = WeeklyReports.digest(files, now: Date())
        weeklyMarkdown = digest.markdown
        weeklyDigest = digest
        reportFiles = files
        let space = WeeklyReports.space(files)
        spaceReport = space
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
        let digest = WeeklyReports.digest(currentReportFiles(), now: Date())
        weeklyMarkdown = digest.markdown
        do {
            let path = try WeeklyReports.write(digest, desktop: DefaultLocations.desktop(home: homeDirectory), now: Date(), store: store)
            setStatus("周报已写入 \(path)", page: .weekly)
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
        setStatus("已导入 \(parsed.count) 条发布记录", page: .tracking)
    }

    func authorize(_ platform: PublishPlatform) {
        let clientID = clientID(for: platform)
        guard !clientID.isEmpty else {
            lastError = "先在设置里填写 \(platform.displayName) 的 Client ID。"
            return
        }
        let url = OAuthEndpoints.authorizeURL(platform: platform, clientID: clientID, redirect: OAuthEndpoints.callbackURL, state: installID)
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
        let form = OAuthEndpoints.tokenForm(platform: platform, code: code, clientID: clientID, clientSecret: secretText, redirect: OAuthEndpoints.callbackURL)
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
            let note = "已同步 \(videos.count) 条 \(platform.displayName) 发布记录"
            self.setStatus(note, page: .tracking)
            self.oauthNote = note
            self.platformLinked[platform.rawValue] = true
            self.platformSyncedAt[platform.rawValue] = Date()
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
        platformSecretSaved[platform.rawValue] = true
        let secretName: String
        switch platform {
        case .youtube, .tiktok: secretName = "Client Secret"
        case .facebook: secretName = "App Secret"
        }
        oauthNote = "\(platform.displayName) 的 \(secretName) 已放进钥匙串，不会写进 JSON。"
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
            setStatus("已写出 \(files.count) 个文件和 SHA256 清单", page: .library)
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
        // 菜单栏改由 MenuBarExtra 直接读 pendingCount，不再另建一个状态栏项。
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

    func finishOnboarding(library: String, roots: [String], watch: Bool) {
        let libraryPath = library.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !libraryPath.isEmpty else {
            lastError = "先选择素材库。"
            return
        }
        let chosen = DefaultLocations.orderedScanRoots(roots, home: homeDirectory)
        guard !chosen.isEmpty else {
            lastError = "至少选择一个扫描位置。"
            return
        }
        preferences.libraryRoot = libraryPath
        preferences.scanRoots = chosen
        preferences.watchEnabled = watch
        desk.onboardingDone = true
        reloadLibrary()
        savePreferences()
        beginScan()
    }

    func selectFiltered(_ on: Bool) {
        let ids = Set(filteredItems.map(\.id))
        if on {
            let movable = Set(filteredItems.filter { $0.disposition != .blocked }.map(\.id))
            selectedIDs.formUnion(movable)
        } else {
            selectedIDs.subtract(ids)
        }
    }

    func slot(of item: PlannedMove) -> DeskSlot {
        if let raw = item.deskSlot, let slot = DeskSlot(rawValue: raw) { return slot }
        let relative = PathKey.relative(file: item.destinationPath, root: preferences.libraryRoot) ?? item.destinationPath
        let ranked = DeskSlot.allCases.map { ($0, desk.relative(for: $0)) }.sorted { $0.1.count > $1.1.count }
        for (slot, folder) in ranked where relative == folder || relative.hasPrefix(folder + "/") {
            return slot
        }
        return .otherMedia
    }

    func leavesOnOtherDisk(_ item: PlannedMove) -> Bool {
        guard desk.moveOnly else { return false }
        return !store.sameVolume(item.sourcePath, item.destinationPath)
    }

    func archiveCatalog() -> [ArchiveRecord] {
        let indexed = catalog.entries.sorted { $0.indexedAt > $1.indexedAt }.map(archiveRecord(from:))
        guard !preferences.libraryRoot.isEmpty, let database = ArchiveDatabase.open(path: StorePaths.sqliteFile(preferences.libraryRoot)) else {
            return indexed
        }
        if indexed.isEmpty { return database.search("") }
        return ArchiveQuery.merging(indexed, recognition: database.recognized())
    }

    private func currentReportFiles() -> [ReportFile] {
        if !catalog.entries.isEmpty {
            return WeeklyReports.files(catalog: catalog, library: preferences.libraryRoot)
        }
        return searchAll().map { record in
            ReportFile(
                path: record.path,
                bytes: record.bytes,
                modifiedAt: ISO8601DateFormatter().date(from: record.modifiedAt) ?? .distantPast,
                indexedAt: nil,
                contentClass: record.contentClass,
                publishStatus: record.publishStatus,
                inHistory: record.path.contains("历史版本")
            )
        }
    }

    func archives(matching query: String) -> [ArchiveRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalogHits = archiveCatalog()
        if trimmed.isEmpty { return Array(catalogHits.prefix(8)) }
        if !catalogHits.isEmpty {
            return Array(ArchiveQuery.filter(catalogHits, query: trimmed).prefix(50))
        }
        guard !preferences.libraryRoot.isEmpty,
              let hits = ArchiveDatabase.open(path: StorePaths.sqliteFile(preferences.libraryRoot))?.search(trimmed) else {
            return []
        }
        return Array(ArchiveQuery.filter(hits, query: trimmed).prefix(50))
    }

    func knownProjectTags() -> [String] {
        var tags = ProjectTags.builtins + desk.extraTags
        for entry in catalog.entries {
            let tag = entry.meta?.projectTag ?? ""
            if tag.count >= 2, !tags.contains(tag) { tags.append(tag) }
        }
        return tags
    }

    func categoryBytes() -> [(category: DeskCategory, bytes: Int64)] {
        var totals: [DeskCategory: Int64] = [:]
        for file in reportFiles {
            let category = category(forPath: file.path)
            totals[category, default: 0] += file.bytes
        }
        return DeskCategory.allCases.compactMap { category in
            guard let bytes = totals[category], bytes > 0 else { return nil }
            return (category, bytes)
        }
    }

    func category(forPath path: String) -> DeskCategory {
        let relative = PathKey.relative(file: path, root: preferences.libraryRoot) ?? path
        let ranked = DeskSlot.allCases.map { ($0, desk.relative(for: $0)) }.sorted { $0.1.count > $1.1.count }
        for (slot, folder) in ranked where relative == folder || relative.hasPrefix(folder + "/") || path.contains("/" + folder + "/") {
            return DeskCategory.from(slot: slot)
        }
        return .other
    }

    func refreshPlatformLink() {
        for platform in PublishPlatform.allCases {
            platformLinked[platform.rawValue] = KeychainStore().contains(account: tokenAccount(platform))
            platformSecretSaved[platform.rawValue] = KeychainStore().contains(account: secretAccount(platform))
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "登录时启动需要从「素材整理器.app」打开。\(error.localizedDescription)"
        }
    }

    func openFilePrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
        ].compactMap(URL.init(string:))
        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }

    func moveRoutes(from offsets: IndexSet, to destination: Int) {
        desk.rules.move(fromOffsets: offsets, toOffset: destination)
        savePreferences()
    }

    func setRouteEnabled(_ id: String, _ enabled: Bool) {
        guard let index = desk.rules.firstIndex(where: { $0.id == id }) else { return }
        desk.rules[index].enabled = enabled
        savePreferences()
    }

    func restoreRoute(_ rule: RouteRule, at index: Int) {
        let insertAt = min(max(index, 0), desk.rules.count)
        desk.rules.insert(rule, at: insertAt)
        savePreferences()
    }

    func removeTag(_ tag: String) {
        desk.extraTags.removeAll { $0 == tag }
        savePreferences()
    }

    func setDestination(_ slot: DeskSlot, absolutePath: String) {
        guard let relative = PathKey.relative(file: absolutePath, root: preferences.libraryRoot) else {
            lastError = "请选择素材库里面的文件夹。这里只保存相对路径。"
            return
        }
        desk.destinations[slot.rawValue] = relative
        savePreferences()
    }

    private func archiveRecord(from entry: IndexEntry) -> ArchiveRecord {
        ArchiveRecord(
            id: entry.id,
            fileName: entry.fileName,
            originalName: entry.meta?.originalName ?? entry.fileName,
            kind: entry.kind.rawValue,
            projectTag: entry.meta?.projectTag ?? "",
            modifiedAt: ISO8601DateFormatter().string(from: entry.modifiedAt),
            platform: entry.meta?.platform ?? "",
            publishStatus: entry.meta?.publishStatus ?? "",
            version: entry.meta?.versionLabel ?? "",
            path: PathKey.joining(preferences.libraryRoot, entry.relativePath),
            contentClass: entry.meta?.contentClass ?? "",
            publishedAt: "",
            bytes: entry.bytes,
            reason: ""
        )
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case preview
    case dispatch
    case locations
    case runs
    case library
    case space
    case weekly
    case tracking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: return "待整理"
        case .dispatch: return "待分发"
        case .locations: return "扫描位置"
        case .runs: return "记录"
        case .library: return "资料库"
        case .space: return "空间"
        case .weekly: return "本周"
        case .tracking: return "发布跟踪"
        }
    }

    var symbol: String {
        switch self {
        case .preview: return "tray"
        case .dispatch: return "tray.and.arrow.up"
        case .locations: return "folder"
        case .runs: return "clock.arrow.circlepath"
        case .library: return "square.stack.3d.up"
        case .space: return "internaldrive"
        case .weekly: return "calendar"
        case .tracking: return "paperplane"
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
        case .blocked: return "不移动"
        case .all: return "全部"
        }
    }
}
