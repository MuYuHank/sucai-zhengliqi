import AppKit
import OrganizerCore
import QuickLookThumbnailing
import SwiftUI

enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let page: CGFloat = 20
    static let lg: CGFloat = 24
}

enum OrganizerWindow {
    /// 只有这个窗口是 key、而且它自己的撤销栈是空的，⌘Z 才会撤销文件移动。
    static let main = "organizer-main"
}

enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

extension Color {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static var placeholderWarning: Color {
        dynamic(light: NSColor(hex: UInt32(PlaceholderWarningColor.light)), dark: NSColor(hex: UInt32(PlaceholderWarningColor.dark)))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum DeskCategory: String, CaseIterable, Identifiable, Hashable {
    case social
    case product
    case web
    case other
    case toDelete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .social: return "社媒"
        case .product: return "产品"
        case .web: return "网站相关"
        case .other: return "其他"
        case .toDelete: return "待删"
        }
    }

    var symbol: String {
        switch self {
        case .social: return "photo.on.rectangle.angled"
        case .product: return "shippingbox"
        case .web: return "globe"
        case .other: return "questionmark.folder"
        case .toDelete: return "trash"
        }
    }

    var tint: Color {
        switch self {
        case .social: return .dynamic(light: NSColor(hex: 0xD12D5E), dark: NSColor(hex: 0xFF6B8B))
        case .product: return .dynamic(light: NSColor(hex: 0x5856D6), dark: NSColor(hex: 0x8E8CF2))
        case .web: return .dynamic(light: NSColor(hex: 0x0E7C8E), dark: NSColor(hex: 0x40C8E0))
        case .toDelete: return .dynamic(light: NSColor(hex: 0xB25E00), dark: NSColor(hex: 0xFF9F0A))
        case .other: return .dynamic(light: NSColor(hex: 0x6C6C70), dark: NSColor(hex: 0xAEAEB2))
        }
    }

    static func from(slot: DeskSlot) -> DeskCategory {
        switch slot {
        case .publishedVideo, .pendingVideo, .finishedImage, .screenshot, .audio:
            return .social
        case .product:
            return .product
        case .webMaintenance, .seoGeo:
            return .web
        case .pendingDelete:
            return .toDelete
        case .otherMedia:
            return .other
        }
    }
}

extension DeskSlot {
    var symbol: String {
        switch self {
        case .publishedVideo: return "play.rectangle.fill"
        case .pendingVideo: return "play.rectangle"
        case .finishedImage: return "photo"
        case .screenshot: return "camera.viewfinder"
        case .product: return "shippingbox"
        case .webMaintenance: return "chevron.left.forwardslash.chevron.right"
        case .seoGeo: return "text.magnifyingglass"
        case .pendingDelete: return "trash"
        case .audio: return "waveform"
        case .otherMedia: return "questionmark.folder"
        }
    }
}

enum ConfidenceTier {
    case high
    case mid
    case low

    static func of(_ value: Double) -> ConfidenceTier {
        if value >= 0.90 { return .high }
        if value >= 0.75 { return .mid }
        return .low
    }
}

struct ConfidenceMark: View {
    var value: Double
    var reason: String = ""

    var body: some View {
        switch ConfidenceTier.of(value) {
        case .high:
            EmptyView()
        case .mid:
            Label("中", systemImage: "circle.lefthalf.filled")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .help(helpText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("置信度中")
        case .low:
            Label("低", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DeskCategory.toDelete.tint)
                .labelStyle(.titleAndIcon)
                .help(helpText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("置信度低")
        }
    }

    private var helpText: String {
        let percent = Int((value * 100).rounded())
        if reason.isEmpty { return "识别置信度 \(percent)%" }
        return "识别置信度 \(percent)%：\(reason)"
    }
}

struct Chip: View {
    var text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

enum PathDisplay {
    static func short(_ path: String, home: String) -> String {
        let normalized = PathKey.normalize(path)
        let homePath = PathKey.normalize(home)
        if normalized == homePath { return "~" }
        if normalized.hasPrefix(homePath + "/") {
            return "~" + normalized.dropFirst(homePath.count)
        }
        return normalized
    }

    static func folderTitle(_ path: String) -> String {
        switch PathKey.name(path) {
        case "Downloads": return "下载"
        case "Desktop": return "桌面"
        case "Documents": return "文稿"
        case "Projects": return "项目"
        case "Developer": return "开发"
        default:
            let name = FileManager.default.displayName(atPath: path)
            return name.isEmpty ? PathKey.name(path) : name
        }
    }
}

struct PathLabel: View {
    var path: String
    var home: String

    var body: some View {
        Text(PathDisplay.short(path, home: home))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
    }
}

struct FileThumb: View {
    var path: String
    var kind: MediaKind
    var side: CGFloat = 48
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if kind != .image && kind != .video {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.38))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.05))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: path) {
            guard kind == .image || kind == .video else {
                image = nil
                return
            }
            image = await ThumbnailCache.image(path: path, side: side)
        }
    }

    private var symbol: String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .archive: return "doc.zipper"
        default: return "doc"
        }
    }
}

@MainActor
enum ThumbnailCache {
    static func image(path: String, side: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        let bytes: Data? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage.tiffRepresentation)
            }
        }
        guard let bytes else { return nil }
        return NSImage(data: bytes)
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var caption: String? = nil
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.xxs) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(symbol == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\(title)，\($0)，\(value)" } ?? "\(title)，\(value)")
    }
}

extension View {
    @ViewBuilder
    func pageMargins() -> some View {
        if #available(macOS 15, *) {
            self.contentMargins(.horizontal, 20, for: .scrollContent)
        } else {
            self.padding(.horizontal, Space.page)
        }
    }

    /// 列表不用 inset 自带的大约 16pt。macOS 14 上也用同一套 20pt 行内边距。
    func listPageChrome() -> some View {
        self
            .listStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: Space.page, bottom: 6, trailing: Space.page))
    }

    @ViewBuilder
    func floatingPanelChrome() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
    }
}

/// 系统 `.borderedProminent` 在窗口失活时会变成白底或灰底，macOS 26 的玻璃样式还会把填充拿掉。
/// 可用时用钉死的 sRGB 蓝色，不跟窗口是否为 key window 走，文字是白色。
/// 发送按钮不可用时改成灰色，不再是发灰的蓝色。
struct StableProminentButtonStyle: ButtonStyle {
    var neutralWhenDisabled = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let neutral = neutralWhenDisabled && !isEnabled
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(neutral ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.white))
            .padding(.horizontal, controlSize == .large ? 18 : 14)
            .padding(.vertical, controlSize == .large ? 8 : 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(neutral ? neutralFill : accentFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(neutral ? Color.primary.opacity(0.16) : Color.white.opacity(0.22), lineWidth: 1)
            }
            .opacity(neutral ? 1 : (isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.55))
    }

    private var accentFill: Color {
        let color = colorScheme == .dark
            ? NSColor(srgbRed: 0.039, green: 0.518, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
        return Color(nsColor: color)
    }

    private var neutralFill: Color {
        let color = colorScheme == .dark
            ? NSColor(srgbRed: 0.28, green: 0.28, blue: 0.30, alpha: 1)
            : NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1)
        return Color(nsColor: color)
    }
}

@MainActor
enum AppAppearance {
    static func apply(_ choice: AppearanceChoice) {
        switch choice {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct WindowSizer: NSViewRepresentable {
    var onboarding: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let onboarding = onboarding
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = organizerName
            window.identifier = NSUserInterfaceItemIdentifier(OrganizerWindow.main)
            if onboarding {
                Self.lockOnboarding(window)
                context.coordinator.openedWorkspace = false
                return
            }
            guard !context.coordinator.openedWorkspace else { return }
            context.coordinator.openedWorkspace = true
            Self.openWorkspace(window)
            // SwiftUI 换根视图时会再写一次尺寸。下一轮如果还被引导页的最大尺寸夹住，再设一次。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let window = view.window else { return }
                let content = window.contentRect(forFrameRect: window.frame)
                if content.width < 960 || content.height < 640 {
                    Self.openWorkspace(window)
                }
            }
        }
    }

    private static func lockOnboarding(_ window: NSWindow) {
        window.styleMask.remove(.resizable)
        let size = NSSize(width: 640, height: 500)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
    }

    /// 引导页去掉 `.resizable` 时，AppKit 会把 contentMaxSize 锁成 640×500。
    /// 只加回 `.resizable` 清不掉这把锁，setContentSize 会被夹住，侧栏就画到窗口外面。
    private static func openWorkspace(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        let minContent = NSSize(width: 960, height: 640)
        let target = NSSize(width: 1120, height: 740)
        window.contentMinSize = minContent
        window.contentMaxSize = NSSize(width: 16_000, height: 16_000)
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minContent)).size
        window.maxSize = NSSize(width: 16_000, height: 16_000)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
            if frame.width > visible.width {
                frame.size.width = visible.width
                frame.origin.x = visible.minX
            }
            if frame.height > visible.height {
                frame.size.height = visible.height
                frame.origin.y = visible.minY
            }
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: false)
        if let contentView = window.contentView {
            let rect = window.contentRect(forFrameRect: window.frame)
            contentView.setFrameSize(rect.size)
        }
    }

    final class Coordinator {
        var openedWorkspace = false
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

struct FolderMeasure: Sendable {
    var files: Int
    var bytes: Int64
    var unreadable: Bool

    static func measure(_ path: String) -> FolderMeasure {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return FolderMeasure(files: 0, bytes: 0, unreadable: true)
        }
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return FolderMeasure(files: 0, bytes: 0, unreadable: true)
        }
        var files = 0
        var bytes: Int64 = 0
        var seen = 0
        while let url = enumerator.nextObject() as? URL {
            seen += 1
            if seen > 20_000 { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return FolderMeasure(files: files, bytes: bytes, unreadable: false)
    }
}
