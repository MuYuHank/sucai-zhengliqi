import AppKit
import AVFoundation
import Carbon
import CoreServices
import Foundation
import OrganizerCore
import Security

@MainActor
enum FolderPicker {
    static func choose(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = "选好之后仍要先看预览。产物整理器不会删除文件。"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}

@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()
    private var item: NSStatusItem?

    func install() {
        guard item == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "产物整理器"
        self.item = item
        refresh(pending: 0, today: 0)
    }

    func refresh(pending: Int, today: Int) {
        guard let item else { return }
        item.button?.title = pending > 0 ? "产物 \(pending)" : "产物"
        let menu = NSMenu()
        let todayItem = NSMenuItem(title: "今日归档 \(today)", action: #selector(openWindow), keyEquivalent: "")
        todayItem.target = self
        menu.addItem(todayItem)
        let pendingItem = NSMenuItem(title: "待确认 \(pending)", action: #selector(openWindow), keyEquivalent: "")
        pendingItem.target = self
        menu.addItem(pendingItem)
        let search = NSMenuItem(title: "打开搜索", action: #selector(search), keyEquivalent: "f")
        search.target = self
        menu.addItem(search)
        let scan = NSMenuItem(title: "扫描", action: #selector(scan), keyEquivalent: "r")
        scan.target = self
        menu.addItem(scan)
        let undo = NSMenuItem(title: "撤回上次", action: #selector(undoLast), keyEquivalent: "")
        undo.target = self
        menu.addItem(undo)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开窗口", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func openWindow() {
        Task { @MainActor in AppRuntime.model?.showWindow() }
    }

    @objc private func search() {
        Task { @MainActor in AppRuntime.model?.presentSearch() }
    }

    @objc private func undoLast() {
        Task { @MainActor in AppRuntime.model?.undoLast() }
    }

    @objc private func scan() {
        Task { @MainActor in
            AppRuntime.model?.showWindow()
            AppRuntime.model?.beginScan()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4348_4E57

    func register(_ preference: HotkeyPreference) {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        // Carbon 在主线程回调；回调里不碰 self，只把搜索请求排到主线程。
        let status = InstallEventHandler(target, { _, _, _ in
            HotkeyCenter.fire()
            return noErr
        }, 1, &eventType, nil, &handler)
        guard status == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(preference.keyCode, preference.carbonModifiers, hotKeyID, target, 0, &hotKey)
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    nonisolated private static func fire() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppRuntime.model?.presentSearch()
            }
        }
    }
}

final class FolderWatcher: @unchecked Sendable {
    static let shared = FolderWatcher()
    private let lock = NSLock()
    private var buffer: [String] = []
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.chanwu.fsevents")

    func start(paths: [String]) {
        stop()
        let watched = Array(Set(paths)).filter { !$0.isEmpty }
        guard !watched.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(eventPaths, to: NSArray.self)
            let paths = array.compactMap { $0 as? String }
            watcher.append(paths)
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let copy = Array(Set(buffer)).sorted()
        buffer.removeAll()
        return copy
    }

    private func append(_ paths: [String]) {
        lock.lock()
        buffer.append(contentsOf: paths)
        lock.unlock()
    }
}

struct KeychainStore: SecureStore, Sendable {
    var service: String = "app.chanwu.organizer"

    func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            return nil
        }
        guard status == errSecSuccess else {
            throw OrganizerError.io("钥匙串读取失败（\(status)）")
        }
        return item as? Data
    }

    func write(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(base as CFDictionary, update)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw OrganizerError.io("钥匙串写入失败（\(added)）")
            }
            return
        }
        throw OrganizerError.io("钥匙串更新失败（\(status)）")
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw OrganizerError.io("钥匙串删除失败（\(status)）")
    }
}

enum AVProbe {
    static func durationSeconds(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    static func thumbnail(url: URL, at seconds: Double = 0.5) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch {
            return nil
        }
    }
}

enum HotkeyCapture {
    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= HotkeyModifiers.command }
        if flags.contains(.shift) { value |= HotkeyModifiers.shift }
        if flags.contains(.option) { value |= HotkeyModifiers.option }
        if flags.contains(.control) { value |= HotkeyModifiers.control }
        return value
    }

    static func display(event: NSEvent) -> String {
        var parts: [String] = []
        if event.modifierFlags.contains(.control) { parts.append("⌃") }
        if event.modifierFlags.contains(.option) { parts.append("⌥") }
        if event.modifierFlags.contains(.shift) { parts.append("⇧") }
        if event.modifierFlags.contains(.command) { parts.append("⌘") }
        let character = event.charactersIgnoringModifiers?.uppercased() ?? "键\(event.keyCode)"
        parts.append(character)
        return parts.joined()
    }
}

struct SessionPoster: HTTPPosting, Sendable {
    func post(url: String, body: Data, timeout: TimeInterval) -> Data? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        let json = body.first == UInt8(ascii: "{")
        request.setValue(json ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return SessionGET.wait(request)
    }
}

enum SessionGET {
    static func fetch(url: String, token: String) -> Data? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return wait(request)
    }

    /// 只给本地模型的同步接口用。平台同步走 PlatformClient，不在主线程上等待。
    static func wait(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = DataBox()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            box.data = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + (request.timeoutInterval + 0.5))
        return box.data
    }
}

enum PlatformClient {
    static func get(url: String, token: String) async -> Data? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return await perform(request)
    }

    static func post(url: String, body: Data, timeout: TimeInterval) async -> Data? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        let json = body.first == UInt8(ascii: "{")
        request.setValue(json ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return await perform(request)
    }

    private static func perform(_ request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            return data
        } catch {
            return nil
        }
    }
}

final class DataBox: @unchecked Sendable {
    var data: Data?
}

enum VideoFingerprints {
    static func collect(_ paths: [String]) async -> [String: FrameHash] {
        var output: [String: FrameHash] = [:]
        for path in paths.prefix(40) {
            if let hash = await sample(path) {
                output[path] = hash
            }
        }
        return output
    }

    private static func sample(_ path: String) async -> FrameHash? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 32, height: 32)
        var values: [UInt64] = []
        let seconds = (duration?.isFinite == true) ? max(duration ?? 1, 0.2) : 1
        for fraction in [0.2, 0.5, 0.8] {
            let time = CMTime(seconds: max(0.05, seconds * fraction), preferredTimescale: 600)
            if let result = try? await generator.image(at: time), let hash = grayHash(result.image) {
                values.append(hash)
            }
        }
        guard !values.isEmpty || duration != nil else { return nil }
        return FrameHash(values: values, duration: duration)
    }

    private static func grayHash(_ image: CGImage) -> UInt64? {
        let width = 8
        let height = 8
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        defer { buffer.deallocate() }
        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let gray = Array(UnsafeBufferPointer(start: buffer, count: width * height))
        return PerceptualHash.averageHash(gray: gray, width: width, height: height)
    }
}
