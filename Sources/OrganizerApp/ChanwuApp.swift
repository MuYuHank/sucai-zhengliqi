import AppKit
import SwiftUI

@main
struct ChanwuApp: App {
    @NSApplicationDelegateAdaptor(ChanwuAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppRuntime.attach(model)
        // 菜单栏图标和全局快捷键要等 NSApp 建好以后再装，见 ChanwuAppDelegate。
        // 在 App.init 里 NSApp 还是 nil，直接调用会在启动时崩溃。
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("整理") {
                Button("扫描") { model.beginScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy)
                Button("搜索") { model.presentSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("撤回上次") { model.undoLast() }
                    .disabled(model.isBusy)
                Button("显示窗口") { model.showWindow() }
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 640, height: 760)
        }
    }
}

@MainActor
final class ChanwuAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusBarController.shared.install()
        if let model = AppRuntime.model {
            HotkeyCenter.shared.register(model.hotkey)
            model.refreshMenu()
        }
    }
}

@MainActor
enum AppRuntime {
    static weak var model: AppModel?
    static func attach(_ model: AppModel) {
        self.model = model
    }
}

enum Theme {
    static let seal = Color(red: 0.761, green: 0.227, blue: 0.180)
    static let ink = Color.primary
}
