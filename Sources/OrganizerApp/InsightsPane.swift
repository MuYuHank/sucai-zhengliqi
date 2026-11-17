import AppKit
import OrganizerCore
import SwiftUI

struct SpacePane: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if model.reportFiles.isEmpty {
                    ContentUnavailableView(
                        "还没有体积数据",
                        systemImage: "internaldrive",
                        description: Text("完成一次真正的移动后，这里按类别显示素材库里的文件。不会删除任何文件。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    Text("可以收回约 \(ByteFormat.string(bytes: model.spaceReport.reclaimableBytes))")
                        .font(.largeTitle.weight(.semibold).monospacedDigit())
                    Text("渲染帧、历史版本、缓存和日志。这里只是列出，不会删除。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    categoryBar
                    Text("最大的文件")
                        .font(.title3.weight(.semibold))
                    ForEach(Array(model.spaceReport.largest.enumerated()), id: \.offset) { _, item in
                        fileLine(path: item.path, detail: ByteFormat.string(bytes: item.bytes))
                    }
                    Text("可以收回的文件")
                        .font(.title3.weight(.semibold))
                    ForEach(Array(model.spaceReport.reclaimable.prefix(12).enumerated()), id: \.offset) { _, item in
                        fileLine(path: item.path, detail: "\(item.reason) · \(ByteFormat.string(bytes: item.bytes))")
                    }
                }
            }
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var categoryBar: some View {
        let rows = model.categoryBytes()
        let total = max(rows.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        return VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(rows, id: \.category) { row in
                        Rectangle()
                            .fill(row.category.tint)
                            .frame(width: max(geo.size.width * CGFloat(row.bytes) / CGFloat(total), row.bytes > 0 ? 4 : 0))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            .accessibilityLabel("按类别的体积")
            .accessibilityValue(rows.map { "\($0.category.title) \(ByteFormat.string(bytes: $0.bytes))" }.joined(separator: "，"))
            ForEach(rows, id: \.category) { row in
                HStack(spacing: Space.xs) {
                    Circle().fill(row.category.tint).frame(width: 8, height: 8)
                    Text(row.category.title)
                    Spacer()
                    Text(ByteFormat.string(bytes: row.bytes))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fileLine(path: String, detail: String) -> some View {
        SpaceFileRow(path: path, detail: detail, home: model.homeDirectory) {
            model.reveal(path)
        }
    }
}

private struct SpaceFileRow: View {
    var path: String
    var detail: String
    var home: String
    var reveal: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(PathKey.name(path))
                    .font(.body)
                PathLabel(path: path, home: home)
            }
            Spacer()
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if hovered {
                Button("显示", action: reveal)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("在访达中显示", action: reveal)
        }
    }
}

struct WeeklyPane: View {
    @Bindable var model: AppModel

    var body: some View {
        let digest = model.weeklyDigest
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("本周从周日 0 点算起。产出按文件的修改时间。归档按放进库里的时间。本周搬进来的旧文件，修改时间可能更早，所以两个数字可以不一样。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                HStack(spacing: Space.sm) {
                    StatTile(title: "产出", value: "\(digest?.produced ?? 0)", caption: "修改时间在本周")
                    StatTile(title: "归档", value: "\(digest?.archived ?? 0)", caption: "本周放进库里")
                    StatTile(title: "发布", value: "\(digest?.published ?? 0)", caption: "本周记成已发布")
                    StatTile(
                        title: "待发布",
                        value: "\(digest?.pending ?? 0)",
                        caption: "还没有发布",
                        symbol: (digest?.pending ?? 0) > 0 ? "clock" : nil,
                        tint: (digest?.pending ?? 0) > 0 ? DeskCategory.toDelete.tint : .secondary
                    )
                }
                Text("待发布只是提醒。周报里没有任何删除操作。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("每周日会把同一份数字写到桌面的「\(DefaultLocations.reportFolderName)」。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button("现在写周报") { model.writeWeeklyReport() }
                    .buttonStyle(StableProminentButtonStyle())
                if !model.weeklyMarkdown.isEmpty, let markdown = weeklyBody(model.weeklyMarkdown) {
                    Text(markdown)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.md)
                        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 完整 Markdown 会把换行收成一行。这里只保留行内语法，换行照原样留下。
    private func weeklyBody(_ markdown: String) -> AttributedString? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            var line = String(raw)
            if line.hasPrefix("# ") { line.removeFirst(2) }
            else if line.hasPrefix("- ") { line.removeFirst(2) }
            return line
        }
        let plain = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return try? AttributedString(markdown: plain, options: options)
    }
}

struct TrackingPane: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var importText = ""
    @State private var platform: PublishPlatform = .youtube

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text(syncLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("超过 \(model.desk.pendingVideoDays) 天还没发布的成片")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("导入发布列表") { importing = true }
                        .buttonStyle(.bordered)
                }
                if model.staleVideos.isEmpty {
                    ContentUnavailableView(
                        "没有超期的待发布视频",
                        systemImage: "paperplane",
                        description: Text("匹配上平台的成片会记成已发布。这里只提醒，不删除。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ForEach(model.staleVideos) { video in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.fileName)
                                    .font(.body.weight(.medium))
                                Text(platformName(video.platform))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                PathLabel(path: video.path, home: model.homeDirectory)
                            }
                            Spacer()
                            Button("打开") { NSWorkspace.shared.open(URL(fileURLWithPath: video.path)) }
                        }
                    }
                }
            }
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $importing) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("导入已发布列表")
                    .font(.title3.weight(.semibold))
                Text("CSV 表头可以是「标题,时长,发布日期,编号,平台」。也可以贴 JSON。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Picker("默认平台", selection: $platform) {
                    ForEach(PublishPlatform.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                TextEditor(text: $importText)
                    .font(.body)
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Color.primary.opacity(0.15)))
                HStack {
                    Spacer()
                    Button("取消") { importing = false }
                        .keyboardShortcut(.cancelAction)
                    Button("导入") {
                        model.importPublished(text: importText, platform: platform)
                        importText = ""
                        importing = false
                    }
                    .buttonStyle(StableProminentButtonStyle())
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(Space.lg)
            .frame(width: 520)
        }
    }

    private var syncLine: String {
        let count = model.listings.videos.count
        if count == 0 {
            return "还没有同步发布平台。可以导入 CSV，或在设置里连接账号。打开这一页不会读取钥匙串。"
        }
        return "已导入 \(count) 条发布记录。连接和同步在设置的「发布平台」里。"
    }

    private func platformName(_ raw: String) -> String {
        let name = ArchiveLabels.platform(raw)
        return name.isEmpty ? "未记下平台" : name
    }
}
