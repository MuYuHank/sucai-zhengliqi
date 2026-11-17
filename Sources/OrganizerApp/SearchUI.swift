import AppKit
import OrganizerCore
import QuickLook
import SwiftUI

@MainActor
final class QuickSearchController {
    static let shared = QuickSearchController()
    private var panel: QuickSearchPanel?

    func toggle(model: AppModel) {
        if let panel, panel.isVisible {
            panel.close()
            self.panel = nil
            return
        }
        let panel = QuickSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: QuickSearchView.height(for: 0)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.title = organizerName
        let host = NSHostingView(rootView: QuickSearchView(model: model, close: { [weak panel] in
            panel?.close()
        }, onHeight: { [weak panel] height in
            guard let panel else { return }
            var frame = panel.frame
            let top = frame.maxY
            frame.size.height = height
            frame.origin.y = top - height
            panel.setFrame(frame, display: true)
        }))
        panel.contentView = host
        panel.onResign = { [weak self, weak panel] in
            guard let panel, self?.panel === panel else { return }
            self?.panel = nil
            if panel.isVisible { panel.close() }
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = NSSize(width: 640, height: QuickSearchView.height(for: 0))
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - visible.height * 0.18
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

final class QuickSearchPanel: NSPanel {
    var onResign: (() -> Void)?
    private var closing = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        guard !closing else { return }
        closing = true
        onResign?()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

struct QuickSearchView: View {
    @Bindable var model: AppModel
    var close: () -> Void
    var onHeight: (CGFloat) -> Void = { _ in }

    static func height(for resultCount: Int) -> CGFloat {
        if resultCount <= 0 { return 280 }
        let rows = min(8, resultCount)
        return max(220, CGFloat(rows) * 68 + 92)
    }
    @State private var query = ""
    @State private var source: [ArchiveRecord] = []
    @State private var selection: String?
    @State private var previewURL: URL?
    @State private var monitor: Any?
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hits: [ArchiveRecord] {
        if trimmedQuery.isEmpty { return Array(source.prefix(8)) }
        return Array(ArchiveQuery.filter(source, query: trimmedQuery).prefix(50))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索文件名、原名、项目或识别出的文字", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openCurrent() }
                    .accessibilityLabel("搜索")
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.md)
            if hits.isEmpty {
                ContentUnavailableView {
                    Text(trimmedQuery.isEmpty ? "最近没有归档" : "没有找到「\(trimmedQuery)」")
                } description: {
                    Text(trimmedQuery.isEmpty ? "完成一次真正的移动之后，可以用原名搜到改过名的文件。" : "原名、项目、摘要和识别出的正文也会参与搜索。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(hits) { hit in
                    searchRow(hit)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            HStack {
                Text(trimmedQuery.isEmpty ? "最近归档" : "\(hits.count) 个结果")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↩ 打开  ⌘↩ 访达  ⌘Y 快速查看  ⌘C 复制路径")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.sm)
        }
        .frame(width: 640, height: Self.height(for: hits.count))
        .floatingPanelChrome()
        .quickLookPreview($previewURL)
        .onAppear {
            fieldFocused = true
            source = model.archiveCatalog()
            selection = hits.first?.id
            onHeight(Self.height(for: hits.count))
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.command) else { return event }
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "c" {
                    if NSApp.keyWindow?.firstResponder is NSText { return event }
                    Task { @MainActor in copyCurrentPath() }
                    return nil
                }
                if event.keyCode == 36 || event.keyCode == 76 {
                    Task { @MainActor in revealCurrent() }
                    return nil
                }
                if key == "y" {
                    Task { @MainActor in quickLookCurrent() }
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
        }
        .onChange(of: query) { _, _ in
            if selection == nil || !hits.contains(where: { $0.id == selection }) {
                selection = hits.first?.id
            }
            onHeight(Self.height(for: hits.count))
        }
        .onChange(of: hits.count) { _, count in
            onHeight(Self.height(for: count))
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func searchRow(_ hit: ArchiveRecord) -> some View {
        let selected = selection == hit.id
        return HStack(spacing: Space.sm) {
            FileThumb(path: hit.path, kind: MediaKind(rawValue: hit.kind) ?? .other, side: 36)
            VStack(alignment: .leading, spacing: 2) {
                highlighted(hit.fileName, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                highlighted(subtitle(hit), weight: .regular, base: .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let line = SearchHighlight.recognitionLine(record: hit, query: trimmedQuery) {
                    highlighted(line, weight: .regular, base: .subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.xs)
            Circle()
                .fill(model.category(forPath: hit.path).tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(hit) }
        .accessibilityLabel(hit.fileName)
        .accessibilityValue(subtitle(hit))
    }

    private func highlighted(_ text: String, weight: Font.Weight, base: Font = .body) -> Text {
        let spans = SearchHighlight.spans(in: text, query: trimmedQuery)
        return spans.reduce(Text("")) { partial, span in
            let piece = Text(span.text).font(span.emphasized ? base.weight(.bold) : base.weight(weight))
            return partial + piece
        }
    }

    private func subtitle(_ hit: ArchiveRecord) -> String {
        let category = model.category(forPath: hit.path).title
        let folder = PathKey.name(PathKey.parent(hit.path))
        return SearchRowText.subtitle(
            category: category,
            folder: folder,
            projectTag: hit.projectTag.isEmpty ? hit.recognizedProject : hit.projectTag,
            when: RelativeClock.string(fromISO: hit.modifiedAt)
        )
    }

    private func copyCurrentPath() {
        guard let current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.path, forType: .string)
    }

    private var current: ArchiveRecord? {
        hits.first { $0.id == selection } ?? hits.first
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let index = hits.firstIndex { $0.id == selection } ?? 0
        let next = min(max(index + delta, 0), hits.count - 1)
        selection = hits[next].id
    }

    private func openCurrent() { if let current { open(current) } }
    private func revealCurrent() { if let current { model.reveal(current.path) } }
    private func quickLookCurrent() { if let current { previewURL = URL(fileURLWithPath: current.path) } }

    private func open(_ hit: ArchiveRecord) {
        NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
    }
}

struct MenuBarPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(organizerName)
                    .font(.headline)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .accessibilityHidden(true)
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("设置")
                .help("设置")
            }
            .padding(.horizontal, Space.xs)
            Text("今天归档 \(model.todayArchived) 个 · \(ByteFormat.string(bytes: model.todayArchivedBytes))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.xs)
            if model.pendingCount > 0 {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label {
                        Text("\(model.pendingCount) 个新文件等你确认")
                    } icon: {
                        Image(systemName: "tray.and.arrow.down")
                            .accessibilityHidden(true)
                    }
                    .font(.body.weight(.medium))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(model.pendingCount) 个新文件等你确认")
                    HStack(spacing: Space.xxs) {
                        ForEach(Array(model.pendingPaths.prefix(4).enumerated()), id: \.offset) { _, path in
                            FileThumb(path: path, kind: .other, side: 28)
                        }
                        if model.pendingPaths.count > 4 {
                            Text("+\(model.pendingPaths.count - 4)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("预览并整理") {
                        model.section = .preview
                        model.previewPending()
                        model.showWindow()
                    }
                    .buttonStyle(StableProminentButtonStyle())
                    .controlSize(.large)
                }
                .padding(Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("没有新文件。新文件出现时会显示在这里，确认前不会移动。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
            if !recent.isEmpty {
                Text("最近归档")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xs)
                    .padding(.top, Space.xxs)
                ForEach(recent) { hit in
                    Button {
                        model.reveal(hit.path)
                    } label: {
                        HStack(spacing: Space.xs) {
                            FileThumb(path: hit.path, kind: MediaKind(rawValue: hit.kind) ?? .other, side: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(hit.fileName)
                                    .lineLimit(1)
                                Text(recentSubtitle(hit))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Space.xs)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(hit.fileName)，\(recentSubtitle(hit))")
                }
            }
            Divider()
            MenuRow(title: "搜索", symbol: "magnifyingglass", shortcut: model.hotkey.display) {
                model.presentSearch()
            }
            MenuRow(title: "扫描", symbol: "arrow.clockwise", shortcut: "⌘R") {
                model.showWindow()
                model.beginScan()
            }
            .disabled(model.isBusy || model.needsOnboarding)
            if let record = model.undoCandidate {
                MenuRow(title: undoTitle(record), symbol: "arrow.uturn.backward", shortcut: "⌘Z") {
                    model.undo(record)
                }
                .disabled(model.isBusy)
            } else {
                MenuRow(title: "没有可以撤销的移动", symbol: "arrow.uturn.backward", shortcut: "⌘Z") {}
                    .disabled(true)
            }
            MenuRow(title: "打开主窗口", symbol: "macwindow", shortcut: "⌘0") {
                model.showWindow()
            }
            Divider()
            MenuRow(title: "退出\(organizerName)", symbol: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(Space.sm)
        .frame(width: 320, alignment: .leading)
    }

    private var recent: [ArchiveRecord] {
        Array(model.archives(matching: "").prefix(3))
    }

    private func undoTitle(_ record: RunRecord) -> String {
        let moved = record.operations.filter { $0.action == .moved }.count
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return "撤销 \(formatter.string(from: record.finishedAt)) 移动的 \(moved) 个文件"
    }

    private func recentSubtitle(_ hit: ArchiveRecord) -> String {
        let category = model.category(forPath: hit.path).title
        let when = RelativeClock.string(fromISO: hit.modifiedAt)
        if when.isEmpty { return category }
        return "\(category) · \(when)"
    }
}

private struct MenuRow: View {
    var title: String
    var symbol: String
    var shortcut: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                Text(shortcut)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.xs)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(hovered ? Color.primary.opacity(0.08) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

enum RelativeClock {
    static func string(fromISO value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: value) else { return "" }
        return string(from: date)
    }

    static func string(from date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func runStamp(_ date: Date) -> String {
        let calendar = Calendars.shanghai()
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "zh_CN")))
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
