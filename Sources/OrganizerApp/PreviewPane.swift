import AppKit
import OrganizerCore
import QuickLook
import SwiftUI

struct PreviewPane: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var highlighted: Set<String> = []
    @State private var expanded: [String: Bool] = [:]
    @State private var showInspector = true
    @State private var issuesExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if model.plan != nil && !model.libraryState.hasCompletedDryRun {
                HStack(spacing: Space.xs) {
                    Image(systemName: "info.circle")
                    Text("第一次运行：点「开始演练」只写记录，不会移动文件。")
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(Color.primary.opacity(0.05))
            }
            if let banner = model.undoBanner {
                UndoBannerBar(banner: banner) {
                    model.undoBanner = nil
                    model.undo(banner.record)
                } reveal: {
                    if let path = banner.record.operations.first(where: { $0.action == .moved })?.destination {
                        model.reveal(path)
                    }
                } dismiss: {
                    model.undoBanner = nil
                }
            }
            Group {
                if model.filteredItems.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.filteredItems.isEmpty { bottomBar }
            }
        }
        .toolbar { toolbar }
        .searchable(text: $model.previewQuery, placement: .toolbar, prompt: "筛选文件名或路径")
        .inspector(isPresented: $showInspector) {
            PreviewInspector(model: model, item: inspected)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .quickLookPreview($model.quickLookURL)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.hiddenIDs)
        .onChange(of: model.undoBanner?.id) { _, _ in
            guard let banner = model.undoBanner else { return }
            if banner.dry {
                AccessibilityNotification.Announcement("演练完成，没有移动文件").post()
            } else {
                AccessibilityNotification.Announcement("已移动 \(banner.moved) 个文件").post()
                if banner.moved + banner.copied > 0 {
                    undoManager?.registerUndo(withTarget: model) { target in
                        Task { @MainActor in target.undo(banner.record) }
                    }
                    undoManager?.setActionName("移动 \(banner.moved) 个文件")
                }
            }
        }
        .onKeyPress(.space) {
            toggleHighlighted()
            return .handled
        }
    }

    private var empty: some View {
        Group {
            if model.pendingCount > 0 {
                ContentUnavailableView {
                    Label {
                        Text("有 \(model.pendingCount) 个新文件")
                    } icon: {
                        Image(systemName: "tray").accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("有 \(model.pendingCount) 个新文件")
                } description: {
                    Text("它们还在待整理里，确认之前不会移动。")
                } actions: {
                    Button("查看") { model.previewPending() }
                        .buttonStyle(StableProminentButtonStyle())
                        .controlSize(.large)
                }
            } else if model.plan == nil {
                ContentUnavailableView {
                    Label {
                        Text("还没有待整理的文件")
                    } icon: {
                        Image(systemName: "tray").accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("还没有待整理的文件")
                } description: {
                    Text("扫描之后，这里会按类别列出将要移动的文件。")
                } actions: {
                    Button("扫描") { model.beginScan() }
                        .buttonStyle(StableProminentButtonStyle())
                        .controlSize(.large)
                        .disabled(model.isBusy)
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text("「\(model.filter.title)」里没有文件")
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle").accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("「\(model.filter.title)」里没有文件")
                } description: {
                    Text("换一个筛选，或在设置里调低最低置信度。")
                } actions: {
                    Button("显示全部") { model.filter = .all }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            filterBar
            fileList
        }
    }

    private var filterBar: some View {
        Picker("筛选", selection: $model.filter) {
            ForEach(PreviewFilter.allCases) { filter in
                Text("\(filter.title) \(model.previewCount(filter))").tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.xs)
        .accessibilityLabel("筛选")
    }

    private var fileList: some View {
        List(selection: $highlighted) {
            ForEach(grouped, id: \.0) { category, items in
                Section(isExpanded: expandedBinding(category)) {
                    ForEach(items) { item in
                        row(item, category: category)
                            .tag(item.id)
                    }
                } header: {
                    header(category, items: items)
                }
            }
            if let plan = model.plan, !plan.issues.isEmpty {
                Section(isExpanded: $issuesExpanded) {
                    ForEach(plan.issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.message)
                                .font(.body)
                            PathLabel(path: issue.path, home: model.homeDirectory)
                        }
                    }
                } header: {
                    Text("有 \(plan.issues.count) 个文件夹没能读取")
                }
            }
        }
        .listPageChrome()
    }

    private var grouped: [(DeskCategory, [PlannedMove])] {
        DeskCategory.allCases.compactMap { category in
            let rows = model.filteredItems.filter { DeskCategory.from(slot: model.slot(of: $0)) == category }
            return rows.isEmpty ? nil : (category, rows)
        }
    }

    private func header(_ category: DeskCategory, items: [PlannedMove]) -> some View {
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: Space.xs) {
            Button {
                toggleGroup(items)
            } label: {
                Image(systemName: checkSymbol(items))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择\(category.title)")
            .accessibilityValue(checkValue(items))
            Image(systemName: category.symbol)
                .foregroundStyle(category.tint)
                .accessibilityHidden(true)
            Text(category.title)
                .font(.body.weight(.semibold))
            Text("\(items.count) · \(ByteFormat.string(bytes: bytes))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if category == .toDelete {
                Text("只是归档到「待删」，不会删除")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, Space.xs)
    }

    private func row(_ item: PlannedMove, category: DeskCategory) -> some View {
        let slot = model.slot(of: item)
        let blocked = item.disposition == .blocked
        return HStack(alignment: .center, spacing: Space.sm) {
            Toggle(item.fileName, isOn: checkBinding(item))
                .labelsHidden()
                .disabled(blocked)
            FileThumb(path: item.sourcePath, kind: item.kind, side: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailLine(item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.xs)
            Chip(text: slot.title, symbol: slot.symbol, tint: category.tint)
            ConfidenceMark(value: item.confidence, reason: item.reason)
        }
        .frame(minHeight: 52)
        .opacity(blocked ? 0.55 : 1)
        .contextMenu {
            Button(model.selectedIDs.contains(item.id) ? "取消勾选" : "勾选") {
                if model.selectedIDs.contains(item.id) {
                    model.selectedIDs.remove(item.id)
                } else if !blocked {
                    model.selectedIDs.insert(item.id)
                }
            }
            .disabled(blocked)
            Button("勾选所选") { setHighlighted(true) }
            Button("取消勾选所选") { setHighlighted(false) }
            Button("在访达中显示") { model.reveal(item.sourcePath) }
            Button("快速查看") { model.quickLookURL = URL(fileURLWithPath: item.sourcePath) }
        }
        .help(item.reason.isEmpty ? item.sourcePath : "\(item.reason)\n\(item.sourcePath)")
    }

    private func detailLine(_ item: PlannedMove) -> String {
        var parts: [String] = []
        if item.source != .unknown { parts.append(item.source.displayName) }
        parts.append(item.kind.displayName)
        parts.append(ByteFormat.string(bytes: item.bytes))
        var line = parts.joined(separator: " · ")
        if let original = item.meta?.originalName, original != item.fileName {
            line += "  原名 \(original)"
        }
        if model.leavesOnOtherDisk(item) { line += "  · 其他磁盘，留在原处" }
        return line
    }

    private var inspected: PlannedMove? {
        if let id = highlighted.first, let item = model.visibleItems.first(where: { $0.id == id }) {
            return item
        }
        return model.filteredItems.first { model.selectedIDs.contains($0.id) } ?? model.filteredItems.first
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.right")
            }
            .accessibilityLabel("检查器")
            .help("显示或收起检查器")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Space.sm) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Space.sm)
            Button("取消全选") { model.selectFiltered(false) }
                .buttonStyle(.bordered)
                .disabled(model.movableSelected.isEmpty)
            Button(model.libraryState.hasCompletedDryRun ? (model.movableSelected.isEmpty ? "没有要移动的文件" : "移动 \(model.movableSelected.count) 个文件") : "开始演练") {
                model.askToCommit()
            }
            .buttonStyle(StableProminentButtonStyle())
            .controlSize(.large)
            .disabled(model.movableSelected.isEmpty || model.isBusy)
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    private var summary: String {
        let count = model.movableSelected.count
        let bytes = ByteFormat.string(bytes: model.selectedBytes)
        if count == 0 { return "勾选要移动的文件" }
        if model.selectedDeleteCount > 0 {
            return "已选 \(count) 个 · \(bytes) · 含待删 \(model.selectedDeleteCount) 个"
        }
        return "已选 \(count) 个 · \(bytes)"
    }

    private func expandedBinding(_ category: DeskCategory) -> Binding<Bool> {
        Binding(
            get: { expanded[category.rawValue] ?? (category != .toDelete) },
            set: { expanded[category.rawValue] = $0 }
        )
    }

    private func checkBinding(_ item: PlannedMove) -> Binding<Bool> {
        Binding(
            get: { model.selectedIDs.contains(item.id) },
            set: { on in
                if on { model.selectedIDs.insert(item.id) } else { model.selectedIDs.remove(item.id) }
            }
        )
    }

    private func checkable(_ items: [PlannedMove]) -> [PlannedMove] {
        items.filter { $0.disposition != .blocked }
    }

    private func checkSymbol(_ items: [PlannedMove]) -> String {
        let rows = checkable(items)
        let on = rows.filter { model.selectedIDs.contains($0.id) }.count
        if rows.isEmpty || on == 0 { return "square" }
        if on == rows.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func checkValue(_ items: [PlannedMove]) -> String {
        switch checkSymbol(items) {
        case "checkmark.square.fill": return "全选"
        case "minus.square.fill": return "部分选中"
        default: return "未选"
        }
    }

    private func toggleGroup(_ items: [PlannedMove]) {
        let rows = checkable(items)
        let allOn = !rows.isEmpty && rows.allSatisfy { model.selectedIDs.contains($0.id) }
        for item in rows {
            if allOn { model.selectedIDs.remove(item.id) } else { model.selectedIDs.insert(item.id) }
        }
    }

    private func toggleHighlighted() {
        let ids: Set<String>
        if highlighted.isEmpty, let id = inspected?.id {
            ids = [id]
        } else {
            ids = highlighted
        }
        let turnOn = ids.contains { !model.selectedIDs.contains($0) }
        setHighlighted(turnOn, ids: ids)
    }

    private func setHighlighted(_ on: Bool, ids: Set<String>? = nil) {
        let chosen = ids ?? highlighted
        for id in chosen {
            guard model.visibleItems.first(where: { $0.id == id })?.disposition != .blocked else { continue }
            if on { model.selectedIDs.insert(id) } else { model.selectedIDs.remove(id) }
        }
    }
}

struct UndoBannerBar: View {
    var banner: MoveBanner
    var undo: () -> Void
    var reveal: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: banner.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.failed > 0 ? DeskCategory.toDelete.tint : Color.green)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: Space.sm)
            if banner.record.operations.contains(where: { $0.action == .moved }) {
                Button("在访达中显示", action: reveal)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if !banner.dry && banner.moved + banner.copied > 0 {
                Button("撤销", action: undo)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("撤销这次移动")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭")
            .help("关闭")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Space.page)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        if banner.dry { return "演练完成，没有移动文件。" }
        var parts: [String] = []
        if banner.moved > 0 { parts.append("已移动 \(banner.moved) 个文件") }
        if banner.copied > 0 { parts.append("跨卷复制 \(banner.copied) 个，源文件仍在") }
        if banner.skippedVolume > 0 { parts.append("\(banner.skippedVolume) 个在其他磁盘上，留在原处") }
        if banner.failed > 0 { parts.append("\(banner.failed) 个没有成功") }
        if parts.isEmpty { return banner.record.note }
        return parts.joined(separator: "。") + "。"
    }
}

struct PreviewInspector: View {
    @Bindable var model: AppModel
    var item: PlannedMove?

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(item.fileName)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        HStack {
                            Button("在访达中显示") { model.reveal(item.sourcePath) }
                                .buttonStyle(.bordered)
                            Button("快速查看") { model.quickLookURL = URL(fileURLWithPath: item.sourcePath) }
                                .buttonStyle(.bordered)
                        }
                        if item.kind == .video {
                            VideoScrub(path: item.sourcePath)
                        } else {
                            FileThumb(path: item.sourcePath, kind: item.kind, side: 160)
                        }
                        if let original = item.meta?.originalName, original != item.fileName {
                            labeled("原名", original)
                        }
                        labeled("类别", model.slot(of: item).title)
                        labeled("来源", item.source.displayName)
                        labeled("置信度", "\(Int((item.confidence * 100).rounded()))%")
                        labeled("大小", ByteFormat.string(bytes: item.bytes))
                        labeled("修改时间", item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("从")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            PathLabel(path: item.sourcePath, home: model.homeDirectory)
                            Text("到")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            PathLabel(path: item.destinationPath, home: model.homeDirectory)
                        }
                        if !item.reason.isEmpty {
                            Text("为什么")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(reasons(item.reason), id: \.self) { reason in
                                Text("· \(reason)")
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("选择一个文件", systemImage: "sidebar.right", description: Text("检查器会显示缩略图、路径和归类原因。"))
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func reasons(_ text: String) -> [String] {
        text.split(separator: "。").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

struct VideoScrub: View {
    var path: String
    @State private var fraction = 0.2
    @State private var image: NSImage?
    @State private var bucket = 8
    @State private var duration: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { geo in
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        FileThumb(path: path, kind: .video, side: min(geo.size.width, 240))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onContinuousHover { phase in
                    guard case .active(let location) = phase, geo.size.width > 1 else { return }
                    let next = min(max(location.x / geo.size.width, 0), 1)
                    fraction = next
                    bucket = Int((next * 40).rounded())
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            Slider(value: $fraction, in: 0...1) { Text("预览进度") }
                .onChange(of: fraction) { _, value in
                    bucket = Int((value * 40).rounded())
                }
                .accessibilityValue("第 \(Int(fraction * 100))%")
            Text(duration.map { "时长 \($0)。把指针停在画面上，查看这一帧。" } ?? "把指针停在画面上，查看这一帧。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .task(id: bucket) {
            let url = URL(fileURLWithPath: path)
            guard let seconds = await AVProbe.durationSeconds(url: url) else { return }
            duration = String(format: "%.1f 秒", seconds)
            image = await AVProbe.thumbnail(url: url, at: max(0.05, seconds * (Double(bucket) / 40)))
        }
    }
}
