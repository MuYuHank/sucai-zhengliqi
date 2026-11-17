import AppKit
import OrganizerCore
import QuickLook
import SwiftUI

struct LibraryPane: View {
    @Bindable var model: AppModel
    @State private var packTag = ""
    @State private var packPresented = false

    var body: some View {
        let entries = visibleEntries
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView(
                    "资料库是空的",
                    systemImage: "square.stack.3d.up",
                    description: Text("完成一次真正的移动之后，文件会出现在这里。演练不会写入资料库。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.libraryUsesGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Space.md)], spacing: Space.md) {
                        ForEach(entries) { entry in
                            gridCell(entry)
                        }
                    }
                    .padding(Space.md)
                }
            } else {
                List(entries) { entry in
                    row(entry)
                }
                .listPageChrome()
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "搜索来源、类型或文件名")
        .toolbar { toolbar }
        .quickLookPreview($model.quickLookURL)
        .sheet(isPresented: $packPresented) {
            DeliverySheet(model: model, tag: $packTag) {
                packPresented = false
                model.makeDelivery(tag: packTag)
            } cancel: {
                packPresented = false
            }
        }
    }

    private var visibleEntries: [IndexEntry] {
        model.searchedEntries().filter { entry in
            guard let raw = model.libraryCategory, let category = DeskCategory(rawValue: raw) else { return true }
            return model.category(forPath: PathKey.joining(model.preferences.libraryRoot, entry.relativePath)) == category
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                model.libraryUsesGrid.toggle()
            } label: {
                Label(model.libraryUsesGrid ? "列表" : "网格", systemImage: model.libraryUsesGrid ? "list.bullet" : "square.grid.2x2")
            }
        }
        ToolbarItem {
            Menu {
                Button("导出 CSV") { model.exportCSV() }
                    .disabled(model.catalog.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("交付打包") { packPresented = true }
                .disabled(model.knownProjectTags().isEmpty && model.catalog.entries.isEmpty)
        }
    }

    private func row(_ entry: IndexEntry) -> some View {
        let path = PathKey.joining(model.preferences.libraryRoot, entry.relativePath)
        return HStack(spacing: Space.sm) {
            FileThumb(path: path, kind: entry.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(librarySubtitle(entry, path: path))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu { actions(path) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        .help(path)
    }

    private func librarySubtitle(_ entry: IndexEntry, path: String) -> String {
        let category = model.category(forPath: path).title
        let tag = entry.meta?.projectTag ?? ""
        if tag.isEmpty { return category }
        return "\(category) · \(tag)"
    }

    private func gridCell(_ entry: IndexEntry) -> some View {
        let path = PathKey.joining(model.preferences.libraryRoot, entry.relativePath)
        return VStack(alignment: .leading, spacing: Space.xs) {
            FileThumb(path: path, kind: entry.kind, side: 140)
            Text(entry.fileName)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .contextMenu { actions(path) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        .help(path)
    }

    @ViewBuilder
    private func actions(_ path: String) -> some View {
        Button("打开") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        Button("在访达中显示") { model.reveal(path) }
        Button("快速查看") { model.quickLookURL = URL(fileURLWithPath: path) }
    }
}

struct DeliverySheet: View {
    @Bindable var model: AppModel
    @Binding var tag: String
    var pack: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("交付打包")
                .font(.title3.weight(.semibold))
            Text("只打包这个项目标签下的最新版本。历史版本不会打进去。压缩包里有清单.json，每项带大小和 SHA256。")
                .font(.body)
                .foregroundStyle(.secondary)
            Picker("项目标签", selection: $tag) {
                Text("选择项目").tag("")
                ForEach(model.knownProjectTags(), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            HStack {
                Spacer()
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("打包", action: pack)
                    .buttonStyle(StableProminentButtonStyle())
                    .disabled(tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.lg)
        .frame(width: 420)
        .onAppear {
            if tag.isEmpty { tag = model.knownProjectTags().first ?? "" }
        }
    }
}
