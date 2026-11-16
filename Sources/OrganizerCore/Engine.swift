public import Foundation

struct DiscoveredFile {
    var path: String
    var name: String
    var bytes: Int64
    var modifiedAt: Date
    var parentNames: [String]
    var sniffPrefix: Data
    var sniffSuffix: Data
    var sidecarJSON: String?
    var sidecarText: String?
}

public struct Organizer: Sendable {
    public let store: any FileStore

    public init(store: any FileStore) {
        self.store = store
    }

    public func scanAndPlan(
        preferences: AppPreferences,
        state: LibraryState,
        options: ScanOptions? = nil,
        now: Date = Date(),
        desk: DeskConfig? = nil,
        listings: [PublishedVideo] = [],
        frameHashes: [String: FrameHash] = [:],
        localAI: (any LocalClassifier)? = nil
    ) -> MovePlan {
        let effective = state.applying(preferences)
        let scanOptions = options ?? .make()
        let library = PathKey.normalize(preferences.libraryRoot)
        if preferences.libraryRoot.isEmpty {
            return finish(items: [], issues: [issue(library.isEmpty ? "/" : library, "还没有设置产物库")], library: library, now: now)
        }
        if Safety.isProtected(library) {
            return finish(items: [], issues: [issue(library, "产物库不能放在系统目录里")], library: library, now: now)
        }
        var files: [DiscoveredFile] = []
        var issues: [ScanIssue] = []
        var seen: Set<String> = []
        let guardMode: LibraryGuard = desk == nil ? .skipInside : .desk(desk!)
        for root in preferences.scanRoots {
            let normalized = PathKey.normalize(root)
            if Safety.isProtected(normalized) || PathKey.components(normalized).contains("Library") {
                issues.append(issue(normalized, "这个位置受系统保护，已跳过"))
                continue
            }
            if Safety.wideRoots.contains(normalized) {
                issues.append(issue(normalized, "扫描范围很大，建议改成「下载」或「桌面」"))
            }
            if desk == nil && PathKey.isInsideOrEqual(normalized, root: library) {
                issues.append(issue(normalized, "扫描位置在产物库里面，已跳过"))
                continue
            }
            walk(
                directory: normalized,
                depth: 0,
                maxDepth: max(0, effective.maxDepth),
                library: library,
                options: scanOptions,
                guardMode: guardMode,
                files: &files,
                issues: &issues,
                seen: &seen
            )
        }
        if let desk {
            let product = PathKey.joining(library, desk.relative(for: .product))
            let covered = preferences.scanRoots.contains { root in
                let normalized = PathKey.normalize(root)
                return PathKey.isInsideOrEqual(product, root: normalized) || PathKey.isInsideOrEqual(normalized, root: product)
            }
            if store.exists(product) && !covered {
                walk(
                    directory: product,
                    depth: 0,
                    maxDepth: max(0, effective.maxDepth),
                    library: library,
                    options: scanOptions,
                    guardMode: .desk(desk),
                    files: &files,
                    issues: &issues,
                    seen: &seen
                )
            }
        }
        files.sort { $0.path < $1.path }
        return plan(files: files, issues: issues, library: library, state: effective, now: now, desk: desk, listings: listings, frameHashes: frameHashes, localAI: localAI, markerRoots: markerRoots(for: files))
    }

    public func planSpecificFiles(
        paths: [String],
        preferences: AppPreferences,
        state: LibraryState,
        options: ScanOptions? = nil,
        now: Date = Date(),
        desk: DeskConfig? = nil,
        listings: [PublishedVideo] = [],
        frameHashes: [String: FrameHash] = [:],
        localAI: (any LocalClassifier)? = nil
    ) -> MovePlan {
        let effective = state.applying(preferences)
        let scanOptions = options ?? .make()
        let library = PathKey.normalize(preferences.libraryRoot)
        guard !preferences.libraryRoot.isEmpty, !Safety.isProtected(library) else {
            return finish(items: [], issues: [issue(library, Copy.neverDeletes)], library: library, now: now)
        }
        var files: [DiscoveredFile] = []
        var issues: [ScanIssue] = []
        for path in paths {
            let normalized = PathKey.normalize(path)
            if !store.exists(normalized) {
                issues.append(issue(normalized, "文件已经不在了"))
                continue
            }
            guard let meta = try? store.metadata(normalized) else {
                issues.append(issue(normalized, "无法读取这个路径"))
                continue
            }
            if meta.isSymlink {
                issues.append(issue(normalized, "符号链接已跳过，避免把整理做到链接外面"))
                continue
            }
            if meta.isDirectory {
                issues.append(issue(normalized, "这是文件夹。请把它加进扫描位置，而不是当作一个文件"))
                continue
            }
            if Safety.looksLikeSecret(PathKey.name(normalized)) {
                issues.append(issue(normalized, "看起来像密钥或凭据，未改动"))
                continue
            }
            if let file = discover(path: normalized, meta: meta, options: scanOptions) {
                files.append(file)
            } else {
                issues.append(issue(normalized, "这个文件被跳过了（隐藏文件、空文件或未下完的临时文件）"))
            }
        }
        return plan(files: files, issues: issues, library: library, state: effective, now: now, desk: desk, listings: listings, frameHashes: frameHashes, localAI: localAI, markerRoots: markerRoots(for: files))
    }

    public func execute(
        plan: MovePlan,
        request: ExecuteRequest,
        state: inout LibraryState,
        now: Date = Date(),
        runID: String = UUID().uuidString
    ) throws -> RunRecord {
        guard request.confirmed else { throw OrganizerError.confirmationRequired }
        guard request.planFingerprint == plan.fingerprint else { throw OrganizerError.planFingerprintMismatch }
        guard MovePlan.fingerprint(for: plan.items) == plan.fingerprint else { throw OrganizerError.planTampered }
        let library = PathKey.normalize(plan.libraryRoot)
        guard !library.isEmpty, library != "/" else { throw OrganizerError.missingLibrary }
        guard !Safety.isProtected(library) else { throw OrganizerError.io("产物库不能放在系统目录里") }
        try store.createDirectory(library)
        try store.createDirectory(StorePaths.chanwuDirectory(library))

        let forcedDry = !state.hasCompletedDryRun
        let dry = forcedDry || !request.intendToApply
        var catalog = (try? IndexStore.load(library: library, store: store)) ?? .empty()
        let archive = ArchiveDatabase.open(path: StorePaths.sqliteFile(library))
        var operations: [RunOperation] = []
        var changedIndex = false

        for item in plan.items where item.meta?.inPlace == true {
            remember(item, library: library, indexedAt: now, catalog: &catalog, archive: archive)
            changedIndex = true
        }

        for item in plan.items where request.selectedIDs.contains(item.id) {
            if item.disposition == .blocked {
                operations.append(operation(item, action: .skipped, reason: item.reason, from: item.sourcePath, to: item.destinationPath))
                continue
            }
            if dry {
                operations.append(operation(item, action: .wouldMove, reason: forcedDry ? "首次运行只演练" : "演练", from: item.sourcePath, to: item.destinationPath))
                continue
            }
            if !PathKey.isInsideOrEqual(item.destinationPath, root: library) || item.destinationPath == library {
                operations.append(operation(item, action: .failed, reason: "目标不在产物库内，已拒绝", from: item.sourcePath, to: item.destinationPath))
                continue
            }
            if PathKey.isInsideOrEqual(item.destinationPath, root: item.sourcePath) || Safety.isProtected(item.sourcePath) || Safety.looksLikeSecret(PathKey.name(item.sourcePath)) {
                operations.append(operation(item, action: .skipped, reason: "源路径不安全，已拒绝", from: item.sourcePath, to: item.destinationPath))
                continue
            }
            if request.moveOnly && !store.sameVolume(item.sourcePath, item.destinationPath) {
                operations.append(operation(item, action: .skipped, reason: "跨卷无法在不删除源文件的前提下移动，已留下原文件", from: item.sourcePath, to: item.destinationPath))
                continue
            }
            do {
                let kind = try store.relocate(from: item.sourcePath, to: item.destinationPath)
                let action: FileAction = kind == .moved ? .moved : .copiedSourceRetained
                let reason = kind == .moved ? "已移动" : "跨卷，已复制并保留源文件"
                operations.append(operation(item, action: action, reason: reason, from: item.sourcePath, to: item.destinationPath))
                remember(item, library: library, indexedAt: now, catalog: &catalog, archive: archive)
                changedIndex = true
            } catch {
                operations.append(operation(item, action: .failed, reason: String(describing: error), from: item.sourcePath, to: item.destinationPath))
            }
        }

        if changedIndex {
            try IndexStore.save(catalog, library: library, store: store)
        }

        let selectedWork = operations.contains { $0.action == .wouldMove }
        let hadMovable = plan.items.contains { $0.disposition == .proposed || $0.disposition == .optional }
        let note: String
        if dry && forcedDry {
            note = Copy.firstRunNote
            if !hadMovable || selectedWork {
                state.hasCompletedDryRun = true
            }
        } else if dry {
            note = Copy.explicitDryRunNote
        } else {
            note = Copy.appliedNote
        }

        let record = RunRecord(
            schema: 1,
            id: runID,
            startedAt: now,
            finishedAt: now,
            mode: dry ? .dryRun : .applied,
            libraryRoot: library,
            planFingerprint: plan.fingerprint,
            undoOfRunID: nil,
            note: note,
            operations: operations
        )
        try RunArchive.save(record, store: store)
        try StateStore.save(state, library: library, store: store)
        return record
    }

    public func undo(
        runID: String,
        library: String,
        now: Date = Date(),
        undoID: String = UUID().uuidString
    ) throws -> RunRecord {
        let root = PathKey.normalize(library)
        let original = try RunArchive.load(library: root, id: runID, store: store)
        var catalog = (try? IndexStore.load(library: root, store: store)) ?? .empty()
        let archive = ArchiveDatabase.open(path: StorePaths.sqliteFile(root))
        var operations: [RunOperation] = []
        var changedIndex = false
        let reversible = original.operations.filter { $0.action == .moved || $0.action == .copiedSourceRetained }

        if reversible.isEmpty {
            let record = undoRecord(id: undoID, now: now, library: root, original: original, note: Copy.undoEmpty, operations: [])
            try RunArchive.save(record, store: store)
            return record
        }

        for operation in reversible.reversed() {
            if operation.action == .copiedSourceRetained {
                operations.append(RunOperation(
                    id: operation.id + "-undo",
                    source: operation.destination,
                    destination: operation.source,
                    action: .skipped,
                    reason: Copy.undoCopyKept,
                    bytes: operation.bytes,
                    sourceTool: operation.sourceTool,
                    kind: operation.kind
                ))
                continue
            }
            let from = operation.destination
            let to = operation.source
            if !store.exists(from) {
                operations.append(undone(operation, action: .failed, reason: Copy.undoMissing, from: from, to: to))
                continue
            }
            archive?.remove(path: from)
            if store.exists(to) {
                operations.append(undone(operation, action: .failed, reason: Copy.undoConflict, from: from, to: to))
                continue
            }
            do {
                _ = try store.relocate(from: from, to: to)
                operations.append(undone(operation, action: .undone, reason: "已移回原处", from: from, to: to))
                if let relative = PathKey.relative(file: from, root: root) {
                    IndexStore.remove(relativePath: relative, catalog: &catalog)
                    changedIndex = true
                }
            } catch {
                operations.append(undone(operation, action: .failed, reason: String(describing: error), from: from, to: to))
            }
        }

        if changedIndex {
            try IndexStore.save(catalog, library: root, store: store)
        }
        let record = undoRecord(id: undoID, now: now, library: root, original: original, note: "已按运行记录 \(runID) 尝试撤销。", operations: operations)
        try RunArchive.save(record, store: store)
        return record
    }

    private enum LibraryGuard {
        case skipInside
        case desk(DeskConfig)
    }

    private func walk(
        directory: String,
        depth: Int,
        maxDepth: Int,
        library: String,
        options: ScanOptions,
        guardMode: LibraryGuard,
        files: inout [DiscoveredFile],
        issues: inout [ScanIssue],
        seen: inout Set<String>
    ) {
        if files.count >= options.maxFiles {
            issues.append(issue(directory, "文件数量达到上限 \(options.maxFiles)，其余未扫描"))
            return
        }
        switch guardMode {
        case .skipInside:
            if PathKey.isInsideOrEqual(directory, root: library) { return }
        case .desk(let config):
            if skipsDesk(directory, library: library, config: config) { return }
        }
        let children: [DiskEntry]
        do {
            children = try store.children(of: directory)
        } catch {
            issues.append(issue(directory, "无法读取文件夹：\(error)"))
            return
        }
        let isProject = children.contains { child in
            Safety.projectMarkers.contains(child.name)
                || child.name.hasSuffix(".xcodeproj")
                || child.name.hasSuffix(".xcworkspace")
        }
        if isProject {
            issues.append(issue(directory, "这像是项目目录，源码不会移动。只会看 output、generated 这类产物文件夹"))
            for child in children where child.isDirectory && !child.isSymlink {
                guard Safety.outputDirectoryNames.contains(child.name.lowercased()) else { continue }
                guard depth + 1 <= maxDepth else { continue }
                walk(directory: child.path, depth: depth + 1, maxDepth: maxDepth, library: library, options: options, guardMode: guardMode, files: &files, issues: &issues, seen: &seen)
            }
            return
        }
        for child in children {
            if files.count >= options.maxFiles {
                issues.append(issue(directory, "文件数量达到上限 \(options.maxFiles)，其余未扫描"))
                return
            }
            if child.name.hasPrefix(".") { continue }
            if child.isSymlink { continue }
            if Safety.ignoredDirectoryNames.contains(child.name) || Safety.isAppBundle(child.name) || child.name == "Library" { continue }
            if Safety.looksLikeSecret(child.name) {
                issues.append(issue(child.path, "看起来像密钥或凭据，未改动"))
                continue
            }
            if case .skipInside = guardMode, PathKey.isInsideOrEqual(child.path, root: library) { continue }
            if child.isDirectory {
                if depth + 1 <= maxDepth {
                    walk(directory: child.path, depth: depth + 1, maxDepth: maxDepth, library: library, options: options, guardMode: guardMode, files: &files, issues: &issues, seen: &seen)
                }
                continue
            }
            guard seen.insert(child.path).inserted else { continue }
            guard let meta = try? store.metadata(child.path) else { continue }
            if let file = discover(path: child.path, meta: meta, options: options) {
                files.append(file)
            }
        }
    }

    private func discover(path: String, meta: DiskMetadata, options: ScanOptions) -> DiscoveredFile? {
        if meta.isDirectory || meta.isSymlink || meta.bytes <= 0 { return nil }
        let name = PathKey.name(path)
        if name.hasPrefix(".") { return nil }
        if Safety.junkNames.contains(name.lowercased()) { return nil }
        let ext = PathKey.fileExtension(name)
        if Safety.partialExtensions.contains(ext) { return nil }
        let sniff = meta.bytes <= options.sniffCeiling
        let prefix = sniff ? ((try? store.readPrefix(path, maxBytes: Limits.sniffBytes)) ?? Data()) : Data()
        let suffix = sniff ? ((try? store.readSuffix(path, maxBytes: Limits.sniffBytes)) ?? Data()) : Data()
        let sidecars = sidecarTexts(path: path, name: name)
        return DiscoveredFile(
            path: path,
            name: name,
            bytes: meta.bytes,
            modifiedAt: meta.modifiedAt,
            parentNames: Array(PathKey.components(path).dropLast()),
            sniffPrefix: prefix,
            sniffSuffix: suffix,
            sidecarJSON: sidecars.json,
            sidecarText: sidecars.text
        )
    }

    private func sidecarTexts(path: String, name: String) -> (json: String?, text: String?) {
        let parent = PathKey.parent(path)
        let stem = Sanitizer.stemAndExtension(name).0
        let jsonNames = [stem + ".json", name + ".json"].filter { $0 != name }
        let textNames = [stem + ".txt", name + ".txt"].filter { $0 != name }
        return (readSmallText(parent: parent, names: jsonNames, max: Limits.maxSidecarBytes),
                readSmallText(parent: parent, names: textNames, max: 200_000))
    }

    private func readSmallText(parent: String, names: [String], max: Int) -> String? {
        for name in names {
            let path = PathKey.joining(parent, name)
            guard store.exists(path), let meta = try? store.metadata(path), !meta.isDirectory, !meta.isSymlink else { continue }
            guard meta.bytes > 0, meta.bytes <= Int64(max) else { continue }
            guard let data = try? store.readFile(path, maxBytes: max) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private func plan(
        files: [DiscoveredFile],
        issues: [ScanIssue],
        library: String,
        state: LibraryState,
        now: Date,
        desk: DeskConfig? = nil,
        listings: [PublishedVideo] = [],
        frameHashes: [String: FrameHash] = [:],
        localAI: (any LocalClassifier)? = nil,
        markerRoots: Set<String> = []
    ) -> MovePlan {
        if let desk {
            return deskPlan(files: files, issues: issues, library: library, state: state, now: now, desk: desk, listings: listings, frameHashes: frameHashes, localAI: localAI, markerRoots: markerRoots)
        }
        var taken: Set<String> = []
        var usedIDs: Set<String> = []
        var items: [PlannedMove] = []
        let calendar = Calendars.shanghai()
        for file in files {
            let identification = Identifier.identify(
                name: file.name,
                parentNames: file.parentNames,
                sniffPrefix: file.sniffPrefix,
                sniffSuffix: file.sniffSuffix,
                sidecarJSON: file.sidecarJSON,
                sidecarText: file.sidecarText,
                userRules: state.userRules
            )
            let id = uniqueID(for: file.path, used: &usedIDs)
            if Safety.isProtected(file.path) {
                items.append(move(id: id, file: file, identification: identification, destination: file.path, disposition: .blocked, reason: "受保护路径"))
                continue
            }
            if PathKey.isInsideOrEqual(file.path, root: library) {
                items.append(move(id: id, file: file, identification: identification, destination: file.path, disposition: .blocked, reason: "已在产物库中"))
                continue
            }
            let allowed = PlanGate.allows(identification, state: state)
            if identification.source == .unknown && !allowed {
                continue
            }
            let folder = destinationFolder(library: library, identification: identification, modified: file.modifiedAt, calendar: calendar)
            let destination = allocateDestination(directory: folder, fileName: file.name, taken: &taken)
            if allowed {
                items.append(move(id: id, file: file, identification: identification, destination: destination, disposition: .proposed, reason: "可以移动"))
            } else {
                items.append(move(id: id, file: file, identification: identification, destination: destination, disposition: .optional, reason: "置信度不足，默认不移动"))
            }
        }
        return finish(items: items, issues: issues, library: library, now: now)
    }

    private func destinationFolder(library: String, identification: Identification, modified: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: modified)
        let year = String(format: "%04d", parts.year ?? 1970)
        let month = String(format: "%02d", parts.month ?? 1)
        return PathKey.joining(library, "\(identification.source.directoryName)/\(identification.kind.directoryName)/\(year)/\(month)")
    }

    private func allocateDestination(directory: String, fileName: String, taken: inout Set<String>) -> String {
        let safe = Sanitizer.fileName(fileName)
        let split = Sanitizer.stemAndExtension(safe)
        var candidate = PathKey.joining(directory, safe)
        var index = 2
        while taken.contains(candidate) || store.exists(candidate) {
            candidate = PathKey.joining(directory, Sanitizer.collisionName(stem: split.0, ext: split.1, index: index))
            index += 1
            if index > Limits.collisionLimit { break }
        }
        taken.insert(candidate)
        return candidate
    }

    private func finish(items: [PlannedMove], issues: [ScanIssue], library: String, now: Date) -> MovePlan {
        MovePlan(
            schema: 1,
            fingerprint: MovePlan.fingerprint(for: items),
            libraryRoot: library,
            createdAt: now,
            items: items,
            issues: issues
        )
    }

    private func move(
        id: String,
        file: DiscoveredFile,
        identification: Identification,
        destination: String,
        disposition: Disposition,
        reason: String
    ) -> PlannedMove {
        PlannedMove(
            id: id,
            sourcePath: file.path,
            destinationPath: destination,
            fileName: file.name,
            bytes: file.bytes,
            modifiedAt: file.modifiedAt,
            source: identification.source,
            kind: identification.kind,
            confidence: identification.confidence,
            evidence: identification.evidence,
            disposition: disposition,
            reason: reason
        )
    }

    private func uniqueID(for path: String, used: inout Set<String>) -> String {
        let base = String(SHA256.hex(Data(path.utf8)).prefix(16))
        if used.insert(base).inserted { return base }
        var index = 2
        while !used.insert("\(base)-\(index)").inserted { index += 1 }
        return "\(base)-\(index)"
    }

    private func issue(_ path: String, _ message: String) -> ScanIssue {
        ScanIssue(id: String(SHA256.hex(Data((path + message).utf8)).prefix(12)), path: path, message: message)
    }

    private func operation(_ item: PlannedMove, action: FileAction, reason: String, from: String, to: String) -> RunOperation {
        RunOperation(id: item.id, source: from, destination: to, action: action, reason: reason, bytes: item.bytes, sourceTool: item.source, kind: item.kind)
    }

    private func undone(_ operation: RunOperation, action: FileAction, reason: String, from: String, to: String) -> RunOperation {
        RunOperation(id: operation.id + "-undo", source: from, destination: to, action: action, reason: reason, bytes: operation.bytes, sourceTool: operation.sourceTool, kind: operation.kind)
    }

    private func undoRecord(id: String, now: Date, library: String, original: RunRecord, note: String, operations: [RunOperation]) -> RunRecord {
        RunRecord(
            schema: 1,
            id: id,
            startedAt: now,
            finishedAt: now,
            mode: .undo,
            libraryRoot: library,
            planFingerprint: original.planFingerprint,
            undoOfRunID: original.id,
            note: note,
            operations: operations
        )
    }

    private func indexEntry(_ item: PlannedMove, library: String, indexedAt: Date) -> IndexEntry? {
        guard let relative = PathKey.relative(file: item.destinationPath, root: library), !relative.isEmpty else { return nil }
        return IndexEntry(
            id: String(SHA256.hex(Data(relative.utf8)).prefix(16)),
            relativePath: relative,
            fileName: PathKey.name(item.destinationPath),
            source: item.source,
            kind: item.kind,
            confidence: item.confidence,
            bytes: item.bytes,
            modifiedAt: item.modifiedAt,
            indexedAt: indexedAt,
            originPath: item.sourcePath,
            evidence: item.evidence,
            meta: item.meta
        )
    }

    private func remember(_ item: PlannedMove, library: String, indexedAt: Date, catalog: inout Catalog, archive: ArchiveDatabase?) {
        if let entry = indexEntry(item, library: library, indexedAt: indexedAt) {
            IndexStore.upsert(&catalog, entry: entry)
        }
        archive?.upsert(ArchiveRecord.from(item: item, indexedAt: indexedAt))
    }

    private func markerRoots(for files: [DiscoveredFile]) -> Set<String> {
        var roots: Set<String> = []
        var seen: Set<String> = []
        for file in files {
            var cursor = PathKey.parent(file.path)
            var steps = 0
            while cursor != "/" && steps < 16 {
                if !seen.insert(cursor).inserted { break }
                if let children = try? store.children(of: cursor),
                   children.contains(where: { ProjectTags.isMarker($0.name) }),
                   !ProjectTags.isGeneric(PathKey.name(cursor)) {
                    roots.insert(cursor)
                }
                let next = PathKey.parent(cursor)
                if next == cursor { break }
                cursor = next
                steps += 1
            }
        }
        return roots
    }

    private func skipsDesk(_ directory: String, library: String, config: DeskConfig) -> Bool {
        guard let relative = PathKey.relative(file: directory, root: library), !relative.isEmpty else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        if parts.contains("历史版本") { return true }
        if let top = parts.first, config.reservedTopLevels().contains(top) { return true }
        return false
    }

    private func deskPlan(
        files: [DiscoveredFile],
        issues: [ScanIssue],
        library: String,
        state: LibraryState,
        now: Date,
        desk: DeskConfig,
        listings: [PublishedVideo],
        frameHashes: [String: FrameHash],
        localAI: (any LocalClassifier)?,
        markerRoots: Set<String>
    ) -> MovePlan {
        var siblings: [String: [String]] = [:]
        for file in files {
            siblings[PathKey.parent(file.path), default: []].append(file.name)
        }
        var aiCalls = 0
        let deskFiles: [DeskFile] = files.map { file in
            let identification = Identifier.identify(
                name: file.name,
                parentNames: file.parentNames,
                sniffPrefix: file.sniffPrefix,
                sniffSuffix: file.sniffSuffix,
                sidecarJSON: file.sidecarJSON,
                sidecarText: file.sidecarText,
                userRules: state.userRules
            )
            var suggestion: AISuggestion?
            if let localAI, desk.localAIEnabled, aiCalls < 20, identification.confidence < 0.6 || identification.source == .unknown {
                aiCalls += 1
                let snippet = file.sidecarText ?? String(decoding: file.sniffPrefix.prefix(180), as: UTF8.self)
                suggestion = localAI.suggest(name: file.name, path: file.path, snippet: snippet)
            }
            let hash = frameHashes[file.path]
            return DeskFile(
                id: String(SHA256.hex(Data(file.path.utf8)).prefix(16)),
                path: file.path,
                name: file.name,
                bytes: file.bytes,
                modifiedAt: file.modifiedAt,
                parentNames: file.parentNames,
                siblingNames: siblings[PathKey.parent(file.path)] ?? [file.name],
                identification: identification,
                ai: suggestion,
                duration: hash?.duration,
                frameHash: hash
            )
        }
        let result = DeskPlanner.plan(files: deskFiles, library: library, config: desk, listings: listings, now: now, pathExists: { store.exists($0) }, extraRoots: markerRoots)
        let items = result.items.map { item in
            PlannedMove(
                id: item.id,
                sourcePath: item.sourcePath,
                destinationPath: item.destinationPath,
                fileName: item.fileName,
                bytes: item.bytes,
                modifiedAt: item.modifiedAt,
                source: item.identification.source,
                kind: item.identification.kind,
                confidence: item.confidence,
                evidence: item.identification.evidence + [item.reason],
                disposition: item.disposition,
                reason: item.reason,
                meta: item.meta
            )
        }
        return finish(items: items, issues: issues + result.issues, library: library, now: now)
    }
}

public enum ReportText {
    public static func plan(_ plan: MovePlan) -> String {
        var lines: [String] = []
        lines.append("\(organizerName) \(organizerVersion)")
        lines.append("产物库：\(plan.libraryRoot)")
        lines.append("可移动：\(plan.proposed.count)")
        lines.append("待确认：\(plan.optionalItems.count)")
        lines.append("已拦住：\(plan.blocked.count)")
        lines.append("问题：\(plan.issues.count)")
        lines.append("")
        if !plan.proposed.isEmpty {
            lines.append("可移动")
            for item in plan.proposed {
                lines.append(contentsOf: itemLines(item))
            }
            lines.append("")
        }
        if !plan.optionalItems.isEmpty {
            lines.append("待确认（默认不勾选）")
            for item in plan.optionalItems {
                lines.append(contentsOf: itemLines(item))
            }
            lines.append("")
        }
        if !plan.issues.isEmpty {
            lines.append("扫描问题")
            for issue in plan.issues {
                lines.append("- \(issue.path)：\(issue.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func run(_ record: RunRecord) -> String {
        let moved = record.operations.filter { $0.action == .moved }.count
        let copied = record.operations.filter { $0.action == .copiedSourceRetained }.count
        let failed = record.operations.filter { $0.action == .failed }.count
        let rehearsed = record.operations.filter { $0.action == .wouldMove }.count
        let undone = record.operations.filter { $0.action == .undone }.count
        var counts = "演练 \(rehearsed)，移动 \(moved)，跨卷复制 \(copied)，失败 \(failed)"
        if undone > 0 { counts += "，撤回 \(undone)" }
        return [
            "运行 \(record.id)",
            "模式：\(modeName(record.mode))",
            "时间：\(display(record.finishedAt))",
            record.note,
            counts,
            Copy.neverDeletes,
        ].joined(separator: "\n")
    }

    public static func runs(_ records: [RunRecord]) -> String {
        if records.isEmpty { return "还没有运行记录。" }
        return records.map { record in
            "\(display(record.finishedAt))  \(modeName(record.mode))  \(record.id)  \(record.note)"
        }.joined(separator: "\n")
    }

    private static func itemLines(_ item: PlannedMove) -> [String] {
        [
            "- \(item.fileName)",
            "  来源 \(item.source.displayName) · \(item.kind.displayName) · \(Int((item.confidence * 100).rounded()))% · \(ByteFormat.string(bytes: item.bytes))",
            "  \(item.sourcePath) → \(item.destinationPath)",
            "  依据：\(item.evidence.joined(separator: "；"))",
        ]
    }

    private static func modeName(_ mode: RunMode) -> String {
        switch mode {
        case .dryRun: return "演练"
        case .applied: return "已执行"
        case .undo: return "撤销"
        }
    }

    private static func display(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }
}
