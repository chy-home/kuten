import AppKit
import Foundation

@main
enum VideoChangeApp {
    static func main() {
        if CommandLineTool.runIfNeeded() {
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        mainWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(editMenuItem)

        let appMenu = NSMenu()
        let quitTitle = "退出 Video Change"
        appMenu.addItem(withTitle: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

enum CommandLineTool {
    static func runIfNeeded() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            return false
        }

        do {
            switch command {
            case "--self-test":
                let runtime = try RuntimeResolver.resolve()
                print("python=\(runtime.pythonURL.path)")
                print("script=\(runtime.detectorScriptURL.path)")
                print("ffmpeg=\(runtime.ffmpegURL.path)")
                return true
            case "--detect-summary":
                guard arguments.count >= 2 else {
                    throw AppRuntimeError.invalidDetectorOutput("用法: --detect-summary <video-path>")
                }
                let videoURL = URL(fileURLWithPath: arguments[1])
                let runtime = try RuntimeResolver.resolve()
                let padding = FadeRemovalStrategy.defaultValue.defaultPaddingSettings
                let payload = try DetectorService(runtime: runtime).detectSync(
                    videoURL: videoURL,
                    fadeRemovalStrategy: .defaultValue,
                    fadeLeftPaddingSeconds: padding.leftSeconds,
                    fadeRightPaddingSeconds: padding.rightSeconds
                )
                print("events=\(payload.events.count)")
                print("keep_segments=\(payload.keepSegments.count)")
                return true
            default:
                return false
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            Foundation.exit(2)
        }
    }
}
