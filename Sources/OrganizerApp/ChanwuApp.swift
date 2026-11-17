import AppKit
import OrganizerCore
import SwiftUI

@main
struct ChanwuApp: App {
    @NSApplicationDelegateAdaptor(ChanwuAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppRuntime.attach(model)
        // 菜单栏和全局快捷键要等 NSApp 建好以后再装，见 ChanwuAppDelegate。
        // 在 App.init 里 NSApp 还是 nil。启动也不读钥匙串。
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { model.undoLast() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("重做") { model.redoLast() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("整理") {
                Button("扫描") { model.beginScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.needsOnboarding)
                Button("搜索") { model.presentSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("撤销上次移动") { model.undoLatestMove() }
                    .disabled(model.undoCandidate == nil || model.isBusy)
                Divider()
                Button("全选当前筛选") { model.selectFiltered(true) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("取消全选") { model.selectFiltered(false) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(model.libraryState.hasCompletedDryRun ? "移动所选" : "开始演练") { model.askToCommit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.movableSelected.isEmpty || model.isBusy)
                Divider()
                Button("筛选：可移动") { model.filter = .movable }
                    .keyboardShortcut("1", modifiers: .command)
                Button("筛选：待确认") { model.filter = .optional }
                    .keyboardShortcut("2", modifiers: .command)
                Button("筛选：不移动") { model.filter = .blocked }
                    .keyboardShortcut("3", modifiers: .command)
                Button("筛选：全部") { model.filter = .all }
                    .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("显示窗口") { model.showWindow() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.pendingCount > 0 ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .accessibilityHidden(true)
                if model.pendingCount > 0 {
                    Text("\(model.pendingCount)")
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.pendingCount > 0 ? "\(organizerName)，\(model.pendingCount) 个待整理" : organizerName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsTabs(model: model)
        }
    }
}

@MainActor
final class ChanwuAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let model = AppRuntime.model {
            AppAppearance.apply(AppearanceChoice.resolve(saved: model.preferences.appearance, arguments: CommandLine.arguments))
            HotkeyCenter.shared.register(model.hotkey)
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
