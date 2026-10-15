import SwiftUI
import AppKit
import Prism

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
    }

    func setupMainWindow(_ window: NSWindow) {
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
