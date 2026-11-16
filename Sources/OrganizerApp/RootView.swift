import AppKit
import Combine
import SwiftUI
import OrganizerCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView(model: model)
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .tint(Theme.seal)
        .frame(minWidth: 880, minHeight: 560)
        .alert("这次没有完成", isPresented: errorPresented) {
            Button("好", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog(model.libraryState.hasCompletedDryRun ? "按预览移动文件？" : "先做一次演练？", isPresented: $model.confirming, titleVisibility: .visible) {
            Button(model.libraryState.hasCompletedDryRun ? "移动所选文件" : "开始演练") {
                model.commit()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.libraryState.hasCompletedDryRun
                ? "将处理 \(model.selectedIDs.count) 个文件，大约 \(ByteFormat.string(bytes: model.selectedBytes))。同卷直接移动，跨卷只复制并保留原文件。之后可以用运行记录撤销移动。不会删除任何文件。"
                : "这是这个产物库的第一次运行，只会写演练记录，不会移动文件。演练结束后，再确认一次才会真正移动。")
        }
        .onAppear {
            model.syncWatcher()
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            model.pollWatcher()
        }
        .sheet(isPresented: $model.searchOpen) {
            SearchSheet(model: model)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("产物整理器")
                    .font(.headline)
                Text(model.libraryState.hasCompletedDryRun ? "预览确认后才会移动" : "第一次运行是演练")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            List(WorkspaceSection.allCases, selection: sectionBinding) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            if !model.pendingPaths.isEmpty {
                Button("预览 \(model.pendingPaths.count) 个新文件") {
                    model.previewPending()
                }
                .buttonStyle(.borderedProminent)
                .padding(12)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }

    private var sectionBinding: Binding<WorkspaceSection?> {
        Binding(
            get: { model.section },
            set: { model.section = $0 ?? model.section }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .scan: ScanPage(model: model)
        case .preview: PreviewPage(model: model)
        case .index: IndexPage(model: model)
        case .runs: RunsPage(model: model)
        case .reports: ReportsPage(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("先给产物一个家")
                    .font(.largeTitle.weight(.semibold))
                Text("产物整理器把散落在下载、桌面和各家 AI 工具目录里的图片、视频、音频收进同一个库。它只在你看过预览并确认之后移动文件。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    rule("不删除", "没有删除、清空废纸篓或覆盖同名文件的操作。跨卷时只复制，源文件留在原地。")
                    rule("先看预览", "扫描只生成清单。没勾选、没确认，文件就停在原来的地方。")
                    rule("第一次是演练", "每个产物库的第一次运行只写记录。你核对清单之后，下一次确认才会真正移动。")
                }
                Spacer()
            }
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) {
                Text(model.preferences.libraryRoot.isEmpty ? "产物库还没选" : model.preferences.libraryRoot)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                Button("选择产物库…") { model.chooseLibrary() }
                    .buttonStyle(.borderedProminent)
                Divider()
                Text("扫描位置")
                    .font(.headline)
                if model.preferences.scanRoots.isEmpty {
                    Text("还没有。可以从「下载」或「桌面」开始，也可以自己选文件夹。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.preferences.scanRoots, id: \.self) { root in
                        Text(root).font(.caption.monospaced()).lineLimit(1)
                    }
                }
                HStack {
                    Button("下载") { model.addStandardFolder(.downloadsDirectory) }
                    Button("桌面") { model.addStandardFolder(.desktopDirectory) }
                    Button("其他文件夹…") { model.chooseRoot() }
                }
                Text("默认会在桌面建好社媒、产品、网站相关和待删。待删只是归档，不会自动删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("按这个结构开始") { model.acceptDesktop() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(28)
            .frame(width: 380)
            .background(Color.primary.opacity(0.04))
        }
    }

    private func rule(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct ScanPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                stats
                roots
                if let plan = model.plan, !plan.issues.isEmpty {
                    issues(plan.issues)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("扫描")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FolderDrop.loadDirectories(providers) { path in
                Task { @MainActor in model.addRoot(path) }
            }
            return true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("从这些位置找 AI 产物")
                    .font(.title2.weight(.semibold))
                Text(model.status)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
            Button("开始扫描") { model.beginScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatTile(title: "可移动", value: "\(model.plan?.proposed.count ?? 0)")
            StatTile(title: "待确认", value: "\(model.plan?.optionalItems.count ?? 0)")
            StatTile(title: "已拦住", value: "\(model.plan?.blocked.count ?? 0)")
            StatTile(title: "索引", value: "\(model.catalog.entries.count)")
        }
    }

    private var roots: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("扫描位置").font(.headline)
                Spacer()
                Button("添加…") { model.chooseRoot() }
            }
            if model.preferences.scanRoots.isEmpty {
                ContentUnavailableView("还没有扫描位置", systemImage: "folder", description: Text("添加「下载」或「桌面」，或把文件夹拖到这个窗口。"))
                    .frame(height: 180)
            } else {
                ForEach(model.preferences.scanRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.seal)
                        Text(root).font(.body.monospaced()).lineLimit(1)
                        Spacer()
                        Button("移除") { model.removeRoot(root) }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
            Text("项目目录里的源码不会动，只会看 output、generated 这类产物文件夹。隐藏文件、符号链接和未下完的临时文件会跳过。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func issues(_ issues: [ScanIssue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("扫描时遇到的情况").font(.headline)
            ForEach(issues) { issue in
                Text("\(issue.path)：\(issue.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PreviewPage: View {
    @Bindable var model: AppModel
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            if !model.libraryState.hasCompletedDryRun {
                Text(Copy.firstRunNote)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.seal.opacity(0.12))
            }
            HStack {
                Picker("范围", selection: $model.filter) {
                    ForEach(PreviewFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                Button("全选可移动") {
                    model.selectedIDs = Set(model.plan?.proposed.map(\.id) ?? [])
                }
                Button(model.libraryState.hasCompletedDryRun ? "确认移动" : "完成演练") {
                    model.askToCommit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.plan == nil)
            }
            .padding(16)
            if model.filteredItems.isEmpty {
                ContentUnavailableView(
                    model.plan == nil ? "还没有预览" : "这一栏是空的",
                    systemImage: "checklist",
                    description: Text(model.plan == nil ? "先在「扫描」里跑一遍。" : "换一个范围，或降低设置里的置信度。")
                )
            } else {
                HSplitView {
                    List(model.filteredItems, selection: $selectedID) { item in
                        row(item)
                            .tag(item.id)
                    }
                    detail(model.plan?.items.first { $0.id == selectedID })
                        .frame(minWidth: 280)
                }
            }
            HStack {
                Text("已选 \(model.selectedIDs.count) 个 · \(ByteFormat.string(bytes: model.selectedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle("预览")
    }

    private func row(_ item: PlannedMove) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selectedIDs.contains(item.id) },
                set: { value in
                    if value { model.selectedIDs.insert(item.id) }
                    else { model.selectedIDs.remove(item.id) }
                }
            ))
            .labelsHidden()
            .disabled(item.disposition == .blocked)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).font(.body.weight(.medium))
                Text("\(item.disposition == .optional ? "待确认 · " : "")\(item.source.displayName) · \(item.kind.displayName) · \(Int((item.confidence * 100).rounded()))% · \(ByteFormat.string(bytes: item.bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let original = item.meta?.originalName, original != item.fileName {
                    Text("原名 \(original)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let status = item.meta?.publishStatus, !status.isEmpty {
                    Text(status == "published" ? "已发布 \(item.meta?.platform ?? "")" : "待发布")
                        .font(.caption2)
                        .foregroundStyle(Theme.seal)
                }
                Text(item.reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func detail(_ item: PlannedMove?) -> some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.fileName).font(.title3.weight(.semibold))
                    FileVisual(path: item.sourcePath, kind: item.kind)
                    labeled("来源", item.source.displayName)
                    labeled("类型", item.kind.displayName)
                    labeled("从", item.sourcePath)
                    labeled("到", item.destinationPath)
                    Text("依据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(item.evidence, id: \.self) { line in
                        Text(line).font(.callout)
                    }
                    Button("在访达中显示源文件") { model.reveal(item.sourcePath) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选一个文件", systemImage: "photo", description: Text("右边会显示识别依据。视频和音频会尽量读出时长。"))
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}

struct FileVisual: View {
    var path: String
    var kind: MediaKind
    @State private var duration: String?
    @State private var thumbnail: NSImage?
    @State private var scrub = 0.2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if kind == .image, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if kind == .video {
                Slider(value: $scrub, in: 0...1) { Text("预览进度") }
                    .onChange(of: scrub) { _, value in
                        let fraction = value
                        Task {
                            let url = URL(fileURLWithPath: path)
                            if let seconds = await AVProbe.durationSeconds(url: url) {
                                duration = String(format: "%.1f 秒", seconds)
                                let time = max(0.05, seconds * fraction)
                                thumbnail = await AVProbe.thumbnail(url: url, at: time)
                            }
                        }
                    }
                Text("拖动进度条，或把指针停在画面上，查看这一帧。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let duration {
                Text("时长 \(duration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onContinuousHover { phase in
            guard kind == .video, case .active(let location) = phase else { return }
            let fraction = min(max(location.x / 280, 0), 1)
            scrub = fraction
        }
        .task(id: path) {
            guard kind == .video || kind == .audio else { return }
            let url = URL(fileURLWithPath: path)
            if let seconds = await AVProbe.durationSeconds(url: url) {
                duration = String(format: "%.1f 秒", seconds)
            }
            if kind == .video {
                thumbnail = await AVProbe.thumbnail(url: url, at: 0.5)
            }
        }
    }
}

struct IndexPage: View {
    @Bindable var model: AppModel

    var body: some View {
        let entries = model.searchedEntries()
        let stats = IndexStore.stats(model.catalog)
        return VStack(spacing: 0) {
            HStack {
                TextField("搜索来源、类型或文件名", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Button("导出 CSV") { model.exportCSV() }
                    .disabled(model.catalog.entries.isEmpty)
            }
            .padding(16)
            HStack(spacing: 12) {
                StatTile(title: "文件", value: "\(stats.totalFiles)")
                StatTile(title: "体积", value: ByteFormat.string(bytes: stats.totalBytes))
                ForEach(stats.bySource.prefix(3), id: \.source) { group in
                    StatTile(title: group.source.displayName, value: "\(group.count)")
                }
            }
            .padding(.horizontal, 16)
            if entries.isEmpty {
                ContentUnavailableView("索引是空的", systemImage: "square.stack.3d.up", description: Text("完成一次真正的移动之后，文件会出现在这里。演练不会写入索引。"))
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.fileName).font(.body.weight(.medium))
                        Text("\(entry.source.displayName) · \(entry.kind.displayName) · \(entry.relativePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contextMenu {
                        Button("在访达中显示") {
                            model.reveal(PathKey.joining(model.preferences.libraryRoot, entry.relativePath))
                        }
                    }
                }
            }
        }
        .navigationTitle("索引")
    }
}

struct RunsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.runs.isEmpty {
                ContentUnavailableView("还没有运行记录", systemImage: "clock.arrow.circlepath", description: Text("每次演练、移动和撤销都会留下一条记录。"))
            } else {
                List(model.runs) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(modeTitle(record.mode))
                                .font(.headline)
                            Spacer()
                            Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(record.note)
                            .font(.callout)
                        Text("移动 \(record.operations.filter { $0.action == .moved }.count) · 跨卷复制 \(record.operations.filter { $0.action == .copiedSourceRetained }.count) · 失败 \(record.operations.filter { $0.action == .failed }.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if record.mode == .applied && record.operations.contains(where: { $0.action == .moved || $0.action == .copiedSourceRetained }) && !model.runs.contains(where: { $0.undoOfRunID == record.id }) {
                            Button("撤销这次移动") { model.undo(record) }
                                .disabled(model.isBusy)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("记录")
        .padding(.top, 4)
    }

    private func modeTitle(_ mode: RunMode) -> String {
        switch mode {
        case .dryRun: return "演练"
        case .applied: return "已执行"
        case .undo: return "撤销"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var ruleKeyword = ""
    @State private var ruleSource: SourceTool = .comfyUI
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("产物库") {
                LabeledContent("位置") {
                    Text(model.preferences.libraryRoot.isEmpty ? "未选择" : model.preferences.libraryRoot)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
                Button("更换产物库…") { model.chooseLibrary() }
                Toggle("监视扫描位置里的新文件", isOn: $model.preferences.watchEnabled)
                    .onChange(of: model.preferences.watchEnabled) { _, _ in model.savePreferences() }
                Text("监视只是把新文件放进待预览，不会自动移动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("识别") {
                LabeledContent("最低置信度") {
                    Text("\(Int((model.preferences.minimumConfidence * 100).rounded()))%")
                        .monospacedDigit()
                }
                Slider(value: $model.preferences.minimumConfidence, in: 0.5...0.95, step: 0.01)
                    .onChange(of: model.preferences.minimumConfidence) { _, _ in model.savePreferences() }
                Toggle("连未识别来源的图片、视频、音频也放进预览", isOn: $model.preferences.includeUnidentifiedMedia)
                    .onChange(of: model.preferences.includeUnidentifiedMedia) { _, _ in model.savePreferences() }
                Stepper(value: $model.preferences.maxDepth, in: 0...32) {
                    Text("扫描深度 \(model.preferences.maxDepth) 层")
                }
                .onChange(of: model.preferences.maxDepth) { _, _ in model.savePreferences() }
            }
            Section("我的规则") {
                if model.preferences.userRules.isEmpty {
                    Text("文件名里出现你写的词时，按指定来源归档。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.preferences.userRules) { rule in
                    HStack {
                        Text(rule.keyword)
                        Spacer()
                        Text(rule.source.displayName).foregroundStyle(.secondary)
                        Button("删除") { model.removeRule(rule.id) }
                    }
                }
                TextField("关键词", text: $ruleKeyword)
                Picker("来源", selection: $ruleSource) {
                    ForEach(SourceTool.allCases.filter { $0 != .unknown }, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Button("添加规则") {
                    model.addRule(keyword: ruleKeyword, source: ruleSource)
                    ruleKeyword = ""
                }
            }
            Section("快捷键与钥匙串") {
                LabeledContent("全局快捷键", value: model.hotkey.display)
                Button(model.capturingHotkey ? "请按下组合键，Esc 取消" : "录制新快捷键") {
                    toggleCapture()
                }
                Text(model.keychainNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("安装标识", value: model.installID)
            }
            DeskSettings(model: model)
            Section("安全") {
                Text(Copy.neverDeletes)
                    .font(.callout)
                Button("下次运行重新演练") { model.requireRehearsalAgain() }
                Text("演练状态按产物库分别记录，写在产物库的 .chanwu/state.json 里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .padding(8)
    }

    private func toggleCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            model.capturingHotkey = false
            return
        }
        model.capturingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    model.capturingHotkey = false
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    self.monitor = nil
                }
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return event
            }
            let display = HotkeyCapture.display(event: event)
            let carbon = HotkeyCapture.carbon(from: flags)
            let keyCode = UInt32(event.keyCode)
            Task { @MainActor in
                model.applyHotkey(keyCode: keyCode, modifiers: carbon, display: display)
                model.capturingHotkey = false
                if let monitor { NSEvent.removeMonitor(monitor) }
                self.monitor = nil
            }
            return nil
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

enum FolderDrop {
    static func loadDirectories(_ providers: [NSItemProvider], add: @escaping @Sendable (String) -> Void) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let item = item as? URL {
                    url = item
                } else {
                    url = nil
                }
                guard let url else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
                add(url.path)
            }
        }
    }
}
