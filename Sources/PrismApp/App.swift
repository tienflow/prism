import SwiftUI
import AppKit
import Prism

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // 主窗口通过 .focusedSceneValue 注入的菜单动作包
    @FocusedValue(\.prismMenuActions) private var prismMenuActions

    var body: some Scene {
        WindowGroup {
            MainStudioView()
                .frame(minWidth: 1100, minHeight: 740)
                .background(WindowAccessor { window in
                    appDelegate.setupMainWindow(window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            // 单窗口应用：移除「文件 → 新建窗口」（⌘N）。
            // 多窗口各自持有独立 @State 历史，却全量写同一个 history.json，
            // 并发退出会互相覆盖，因此 Prism 只允许一个主窗口。
            CommandGroup(replacing: .newItem) {}

            // 创作菜单：⌘G 开始生图（原「查找下一个」键位，已在 AppDelegate 清空）；
            // ⌘L 聚焦描述框（浏览器聚焦地址栏的同构操作）。
            // 无修饰键的 I / 空格 / 方向键保留在 NSEvent 本地监听里——
            // 它们必须在文本编辑态自动让位给输入，放进菜单会全局拦截。
            CommandMenu("创作") {
                Button("开始生图") {
                    prismMenuActions?.startGeneration()
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("聚焦描述框") {
                    prismMenuActions?.focusPrompt()
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") {
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }

        Settings {
            PreferencesView()
        }
    }
}

// MARK: - AppKit 委托：接管窗口关闭拦截与 Dock 点击激活还原
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // SwiftUI 未暴露「查找」菜单组的替换位置，默认「查找下一个」占用 ⌘G。
        // 遍历菜单把 findNext:/findPrevious: 的键位清空（菜单项保留，不影响 ⌘F），
        // 让「创作 → 开始生图」的 ⌘G 唯一命中。
        DispatchQueue.main.async { [weak self] in
            self?.neutralizeFindNextShortcuts()
        }
    }

    private func neutralizeFindNextShortcuts() {
        let blocked: Set<Selector> = [Selector(("findNext:")), Selector(("findPrevious:"))]
        func walk(_ items: [NSMenuItem]) {
            for item in items {
                if let submenu = item.submenu {
                    walk(submenu.items)
                } else if let action = item.action, blocked.contains(action) {
                    item.keyEquivalent = ""
                }
            }
        }
        guard let mainMenu = NSApp.mainMenu else { return }
        walk(mainMenu.items)
    }

    func setupMainWindow(_ window: NSWindow) {
        // 双保险：菜单已移除 ⌘N，若 SwiftUI 仍因任何路径创建出第二个窗口，
        // 直接关闭新窗口并激活既有主窗口（避免多窗口并发写 history.json 互相覆盖）。
        if let existing = mainWindow, existing !== window, existing.isVisible {
            window.close()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if self.mainWindow !== window {
            self.mainWindow = window
            window.delegate = self
            window.isReleasedWhenClosed = false
        }
    }

    // 点击红叉关闭主窗口后整个 App 退出（Dock 图标同步消失）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // 点击 Dock 栏图标时无缝激活并拉起主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        let target = mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain })
        target?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SidecarManager.shared.stop()
    }
}

// MARK: - 辅助捕获底层 NSWindow 实例
struct WindowAccessor: NSViewRepresentable {
    var onWindowFound: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowFound(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindowFound(window)
            }
        }
    }
}
