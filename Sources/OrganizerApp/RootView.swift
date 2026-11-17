import AppKit
import OrganizerCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var dropTargeted = false
    @State private var rootPendingRemoval: String?

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
                .frame(minWidth: 1120, minHeight: 640)
            }
        }
        .background(WindowSizer(onboarding: model.needsOnboarding))
        .modifier(RecognitionQuoteDialog(window: .main, model: model))
        .confirmationDialog(
            model.libraryState.hasCompletedDryRun
                ? (model.movableSelected.isEmpty ? "没有要移动的文件" : "移动 \(model.movableSelected.count) 个文件？")
                : "先演练一次？",
            isPresented: $model.confirming,
            titleVisibility: .visible
        ) {
            Button(model.libraryState.hasCompletedDryRun ? (model.movableSelected.isEmpty ? "没有要移动的文件" : "移动 \(model.movableSelected.count) 个文件") : "开始演练") { model.commit() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.confirmMessage)
        }
        .alert("没能完成", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            if model.lastErrorSuggestsPrivacy {
                Button("打开系统设置") { model.openFilePrivacySettings() }
            }
            Button("好") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .confirmationDialog("移出这个扫描位置？", isPresented: Binding(
            get: { rootPendingRemoval != nil },
            set: { if !$0 { rootPendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("移出扫描", role: .destructive) {
                if let rootPendingRemoval { model.removeRoot(rootPendingRemoval) }
                rootPendingRemoval = nil
            }
            Button("取消", role: .cancel) { rootPendingRemoval = nil }
        } message: {
            Text("只是不再扫描这个位置，不会移动或删除里面的文件。")
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("整理") {
                sidebarRow(.preview, badge: model.pendingCount)
                sidebarRow(.dispatch, badge: model.distribution.pending.count)
                sidebarRow(.locations, badge: 0)
                sidebarRow(.runs, badge: 0)
            }
            Section("资料库") {
                libraryRow(nil, title: "全部", symbol: "square.stack.3d.up")
                ForEach(DeskCategory.allCases) { category in
                    libraryRow(category.rawValue, title: category.title, symbol: category.symbol, tint: category.tint)
                }
            }
            Section("洞察") {
                sidebarRow(.space, badge: 0)
                sidebarRow(.weekly, badge: 0)
                sidebarRow(.tracking, badge: 0)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(organizerName)
        .frame(minWidth: 200)
    }

    private var detail: some View {
        NavigationStack {
            Group {
                switch model.section {
                case .preview:
                    PreviewPane(model: model)
                case .dispatch:
                    DispatchQueuePane(model: model)
                case .locations:
                    LocationsPage(model: model, dropTargeted: $dropTargeted, pendingRemoval: $rootPendingRemoval)
                case .runs:
                    RunsPage(model: model)
                case .library:
                    LibraryPane(model: model)
                case .space:
                    SpacePane(model: model)
                case .weekly:
                    WeeklyPane(model: model)
                case .tracking:
                    TrackingPane(model: model)
                }
            }
            .navigationTitle(organizerName)
            .modifier(StatusSubtitle(text: detailSubtitle))
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.beginScan()
                    } label: {
                        Label {
                            Text("扫描")
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                                .accessibilityHidden(true)
                        }
                    }
                    .disabled(model.isBusy)
                    .accessibilityLabel("扫描")
                    .help("重新扫描")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.presentSearch()
                    } label: {
                        Label {
                            Text("搜索")
                        } icon: {
                            Image(systemName: "magnifyingglass")
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("搜索")
                    .keyboardShortcut("f", modifiers: .command)
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .accessibilityHidden(true)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("设置")
                    .help("设置")
                }
            }
        }
    }

    private var detailSubtitle: String {
        let page: String
        switch model.section {
        case .dispatch:
            page = "待分发 · \(model.distribution.pending.count) 条"
        case .preview:
            page = "待整理 · 可移动 \(model.previewCount(.movable)) 个，已勾选 \(model.movableSelected.count) 个"
        case .locations:
            page = "扫描位置 · \(model.preferences.scanRoots.count) 个"
        default:
            page = model.section.title
        }
        if model.status.isEmpty { return page }
        return "\(page) · \(model.status)"
    }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: {
                if model.section == .library {
                    return "library:" + (model.libraryCategory ?? "all")
                }
                return model.section.rawValue
            },
            set: { value in
                guard let value else { return }
                if value.hasPrefix("library:") {
                    model.section = .library
                    let raw = String(value.dropFirst("library:".count))
                    model.libraryCategory = raw == "all" ? nil : raw
                } else if let section = WorkspaceSection(rawValue: value) {
                    model.section = section
                }
            }
        )
    }

    private func sidebarRow(_ section: WorkspaceSection, badge: Int) -> some View {
        HStack {
            Image(systemName: section.symbol)
                .accessibilityHidden(true)
            Text(section.title)
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .accessibilityHidden(true)
            }
        }
        .tag(section.rawValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarAnnouncement.label(
            title: section.title,
            badge: badge,
            unit: section == .dispatch ? "项" : nil
        ))
    }

    private func libraryRow(_ raw: String?, title: String, symbol: String, tint: Color? = nil) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
        }
        .tag("library:" + (raw ?? "all"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct StatusSubtitle: ViewModifier {
    var text: String

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .navigationSubtitle(Text(text))
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                .toolbarBackground(Color(nsColor: NSColor.windowBackgroundColor), for: .windowToolbar)
                .background(TitlebarOpacity())
                .safeAreaInset(edge: .top, spacing: 0) {
                    // 副标题比标题栏多一行。安全区没算上这一行时，滚动内容会从字下面透出来。
                    Color(nsColor: NSColor.windowBackgroundColor)
                        .frame(height: 22)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

/// 透明标题栏会让滚上来的内容从副标题下面透出来，深色里最明显。
private struct TitlebarOpacity: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = false
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
        }
    }
}

struct LocationsPage: View {
    @Bindable var model: AppModel
    @Binding var dropTargeted: Bool
    @Binding var pendingRemoval: String?
    @State private var stats: [String: FolderMeasure] = [:]
    @State private var issuesExpanded = false
    @State private var hoveredRoot: String?
    @FocusState private var focusedRoot: String?

    var body: some View {
        // 只改显示顺序。已经保存的 scanRoots 保持原样，不会悄悄写回。
        let roots = DefaultLocations.orderedScanRoots(model.preferences.scanRoots, home: model.homeDirectory)
        List {
            if roots.isEmpty {
                ContentUnavailableView("还没有扫描位置", systemImage: "folder", description: Text("添加之后才会扫描。这里不会自动把家目录里的文件夹加进来。"))
            } else {
                ForEach(roots, id: \.self) { root in
                    locationRow(root)
                }
            }
            if let plan = model.plan, !plan.issues.isEmpty {
                Section(isExpanded: $issuesExpanded) {
                    ForEach(plan.issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.message)
                            PathLabel(path: issue.path, home: model.homeDirectory)
                            if issue.message.contains("无法读取") || issue.message.contains("权限") {
                                Button("打开系统设置") { model.openFilePrivacySettings() }
                            }
                        }
                    }
                } header: {
                    Text("扫描问题")
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(Space.sm)
                    .allowsHitTesting(false)
            }
        }
        .listPageChrome()
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FolderDrop.loadDirectories(providers) { path in
                Task { @MainActor in model.addRoot(path) }
            }
            return true
        }
        .toolbar {
            ToolbarItem {
                Button("添加文件夹…") { model.chooseRoot() }
            }
        }
        .task(id: roots) {
            await loadStats(roots)
        }
    }

    private func locationRow(_ root: String) -> some View {
        let measure = stats[root]
        return HStack(spacing: Space.sm) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: root))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(PathDisplay.folderTitle(root))
                    .font(.body.weight(.medium))
                PathLabel(path: root, home: model.homeDirectory)
                if let measure {
                    if measure.unreadable {
                        Text("无法读取")
                            .font(.subheadline)
                            .foregroundStyle(DeskCategory.toDelete.tint)
                    } else {
                        Text("\(measure.files) 个文件 · \(ByteFormat.string(bytes: measure.bytes))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("正在计算…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                pendingRemoval = root
            } label: {
                Label("移出扫描", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .focused($focusedRoot, equals: root)
            .opacity(hoveredRoot == root || focusedRoot == root ? 1 : 0.35)
            .accessibilityLabel("移出扫描，\(PathDisplay.folderTitle(root))")
            .help("移出扫描位置，不删除文件")
        }
        .onHover { hovering in
            hoveredRoot = hovering ? root : (hoveredRoot == root ? nil : hoveredRoot)
        }
        .contextMenu {
            Button("在访达中显示") { model.reveal(root) }
            Button("移出扫描") { pendingRemoval = root }
        }
    }

    private func loadStats(_ roots: [String]) async {
        let measured = await Task.detached { () -> [String: FolderMeasure] in
            var result: [String: FolderMeasure] = [:]
            for root in roots {
                result[root] = FolderMeasure.measure(root)
            }
            return result
        }.value
        stats = measured
    }
}

struct RunsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.runs.isEmpty {
                ContentUnavailableView("还没有记录", systemImage: "clock.arrow.circlepath", description: Text("每次演练、移动和撤销都会留下一条记录。"))
            } else {
                List(model.runs) { record in
                    HStack(alignment: .center, spacing: Space.sm) {
                        Image(systemName: symbol(record.mode))
                            .frame(width: 20)
                            .foregroundStyle(record.mode == .applied ? Color.green : Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modeTitle(record.mode))
                                .font(.headline)
                            Text(record.note)
                                .font(.body)
                                .lineLimit(2)
                            let summary = counts(record)
                            if !summary.isEmpty {
                                Text(summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: Space.sm)
                        Text(RelativeClock.runStamp(record.finishedAt))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .help(record.finishedAt.formatted(date: .complete, time: .standard))
                        if record.mode == .applied && record.operations.contains(where: { $0.action == .moved || $0.action == .copiedSourceRetained }) && !model.runs.contains(where: { $0.undoOfRunID == record.id }) {
                            Button("撤销") { model.undo(record) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isBusy)
                                .accessibilityLabel("撤销这次移动")
                        }
                    }
                    .padding(.vertical, Space.xxs)
                }
            }
        }
    }

    private func symbol(_ mode: RunMode) -> String {
        switch mode {
        case .dryRun: return "eye"
        case .applied: return "checkmark.circle.fill"
        case .undo: return "arrow.uturn.backward"
        }
    }

    private func modeTitle(_ mode: RunMode) -> String {
        switch mode {
        case .dryRun: return "演练"
        case .applied: return "已移动"
        case .undo: return "撤销"
        }
    }

    private func counts(_ record: RunRecord) -> String {
        var parts: [String] = []
        let moved = record.operations.filter { $0.action == .moved }.count
        let copied = record.operations.filter { $0.action == .copiedSourceRetained }.count
        let failed = record.operations.filter { $0.action == .failed }.count
        let rehearsed = record.operations.filter { $0.action == .wouldMove }.count
        if rehearsed > 0 { parts.append("演练 \(rehearsed)") }
        if moved > 0 { parts.append("移动 \(moved)") }
        if copied > 0 { parts.append("跨卷复制 \(copied)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        let undone = record.operations.filter { $0.action == .undone }.count
        if undone > 0 { parts.append("移回 \(undone)") }
        return parts.joined(separator: " · ")
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var step = 1
    @State private var library = ""
    @State private var checked: Set<String> = []
    @State private var watch = true
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                ForEach(1...3, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(height: 4)
                }
            }
            .accessibilityLabel("第 \(step) 步，共 3 步")
            Group {
                switch step {
                case 1: stepLibrary
                case 2: stepRoots
                default: stepConfirm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 1 {
                    Button("返回") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(step < 3 ? "继续" : "开始扫描") {
                    if step < 3 {
                        step += 1
                    } else {
                        model.finishOnboarding(library: library, roots: Array(checked), watch: watch)
                    }
                }
                .buttonStyle(StableProminentButtonStyle())
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
            }
        }
        .padding(Space.page)
        .frame(width: 640, height: 500)
        .onAppear(perform: prepare)
    }

    private var primaryDisabled: Bool {
        let missingLibrary = library.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if step == 1 { return missingLibrary }
        if step == 3 { return missingLibrary || checked.isEmpty }
        return false
    }

    private var stepLibrary: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                appIcon
                Text("先给素材一个家")
                    .font(.largeTitle.weight(.semibold))
            }
            Text("\(organizerName)会把散落的图片、视频和交付物收进同一个素材库。它只在你看过预览并确认之后移动文件。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.isEmpty ? "素材库" : PathDisplay.folderTitle(library))
                            .font(.body.weight(.medium))
                        Text(library.isEmpty ? "未选择" : PathDisplay.short(library, home: model.homeDirectory))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("更改…") { chooseLibrary() }
                        .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(DeskCategory.allCases) { category in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Image(systemName: category.symbol)
                                .foregroundStyle(category.tint)
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            Text(category.title)
                                .font(.body)
                                .frame(width: 72, alignment: .leading)
                            Text(slotNames(category))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(category.title)，\(slotNames(category))")
                    }
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.primary.opacity(0.05)))
            Text("默认放在桌面。之后可以在设置里更换。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 44))
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
    }

    private var stepRoots: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("从哪里收集")
                .font(.title2.weight(.semibold))
            Text("只扫描勾选的位置。取消勾选就不会加入。")
                .font(.body)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("常用")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(everyday, id: \.self) { root in
                    rootToggle(root)
                }
                Text("开发工具目录")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, Space.xxs)
                ForEach(development, id: \.self) { root in
                    rootToggle(root)
                }
                if !extras.isEmpty {
                    Text("另外添加的")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, Space.xxs)
                    ForEach(extras, id: \.self) { root in
                        rootToggle(root)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("添加文件夹…") {
                if let path = FolderPicker.choose(prompt: "添加扫描位置") {
                    checked.insert(PathKey.normalize(path))
                }
            }
            .buttonStyle(.bordered)
            Toggle("监视新文件。新文件只会进入待整理，不会自动移动。", isOn: $watch)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FolderDrop.loadDirectories(providers) { path in
                Task { @MainActor in checked.insert(PathKey.normalize(path)) }
            }
            return true
        }
    }

    private var stepConfirm: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("确认之后才开始")
                .font(.largeTitle.weight(.semibold))
            Text("素材库 \(PathDisplay.short(library, home: model.homeDirectory))，扫描 \(checked.count) 个位置。")
                .font(.body)
                .foregroundStyle(.secondary)
            promise("trash.slash", "不删除", "文件只会被移动，或留在原来的地方。")
            promise("eye", "先看预览", "没看过清单、没点确认，什么都不会动。")
            promise("checklist", "第一次是演练", "第一次确认只写记录。演练完再确认一次，才会真正移动。")
            Text("同一块磁盘上直接移动。在其他磁盘上的文件会留在原处，不会复制。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(watch ? "监视开着：新文件进入待整理，不自动移动。" : "监视关着。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "eye" ? 19 : 22, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(promiseTint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)。\(detail)")
    }

    /// 钉死的系统蓝。分层符号的浅色层在白底上只有大约 2:1，单色才过得了 3:1。
    private var promiseTint: Color {
        let color = colorScheme == .dark
            ? NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
        return Color(nsColor: color)
    }

    private func slotNames(_ category: DeskCategory) -> String {
        DeskSlot.allCases.filter { DeskCategory.from(slot: $0) == category }.map(\.title).joined(separator: "、")
    }

    private func chooseLibrary() {
        if let path = FolderPicker.choose(prompt: "设为素材库") {
            library = path
        }
    }

    private var everyday: [String] {
        ["Downloads", "Desktop", "Documents", "Projects"].map { PathKey.joining(model.homeDirectory, $0) }
    }

    private var development: [String] {
        [".codex", ".cursor", "Developer"].map { PathKey.joining(model.homeDirectory, $0) }
    }

    private var extras: [String] {
        checked.subtracting(everyday + development).sorted()
    }

    private func rootToggle(_ root: String) -> some View {
        let title = PathDisplay.folderTitle(root)
        return Toggle(isOn: Binding(
            get: { checked.contains(root) },
            set: { on in
                if on { checked.insert(root) } else { checked.remove(root) }
            }
        )) {
            HStack(spacing: Space.xs) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: root))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                Text(PathDisplay.short(root, home: model.homeDirectory))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .accessibilityLabel(title)
    }

    private func prepare() {
        if library.isEmpty {
            library = model.preferences.libraryRoot.isEmpty
                ? DefaultLocations.desktop(home: model.homeDirectory)
                : model.preferences.libraryRoot
        }
        if checked.isEmpty {
            let defaults = Set(everyday + development)
            if model.preferences.scanRoots.isEmpty {
                checked = defaults
            } else {
                checked = Set(model.preferences.scanRoots.map(PathKey.normalize))
            }
        }
        watch = model.preferences.watchEnabled || model.preferences.scanRoots.isEmpty
    }
}
