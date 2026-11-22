import AppKit
import SwiftUI

/// A borderless panel that closes on Escape and can take keyboard focus.
final class MenuBarPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onClose?()
    }
}

/// A settings window. Escape has nothing to cancel here, so it is ignored instead of
/// playing the alert sound. Cmd-W closes, as in other Mac windows.
final class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil { return }
        super.sendEvent(event)
    }
}

/// Owns the shield in the menu bar, the panel it opens and the app's windows.
/// AppKit replaces SwiftUI's MenuBarExtra, which always drops its panel straight below the icon.
final class MenuBarController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let sample = Sample(rawValue: ProcessInfo.processInfo.environment["CLEARPATH_SAMPLE"] ?? "connected") ?? .unknown
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var hosting: NSHostingView<Panel>!
    private var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = shieldImage(for: sample)
            button.setAccessibilityLabel("Clearpath design preview. \(sample.headline). Partner: \(sample.partner)")
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown])
        }

        hosting = NSHostingView(rootView: Panel(
            sample: sample,
            openPartnerSettings: { [unowned self] in show("partner-settings", "Partner settings", PartnerSettings()) },
            openSetup: { [unowned self] in show("protection-setup", "Set up protection", ProtectionSetup()) }
        ))
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel = MenuBarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onClose = { [unowned self] in statusItem.button?.highlight(false) }
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); return }
        guard let button = statusItem.button, let barWindow = button.window,
              let screen = barWindow.screen ?? NSScreen.main else { return }
        let icon = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hosting.fittingSize
        panel.setFrame(NSRect(origin: panelOrigin(icon: icon, panel: size, screen: screen.visibleFrame), size: size),
                       display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        button.highlight(true)
    }

    // Clicking anywhere outside the panel, including another app, takes focus from it.
    func windowDidResignKey(_ notification: Notification) {
        if panel.attachedSheet == nil { panel.orderOut(nil) }
    }

    private func show<Content: View>(_ id: String, _ title: String, _ view: Content) {
        panel.orderOut(nil)
        // A closed window is rebuilt so its view loads fresh, as SwiftUI's Window scene did.
        let window: NSWindow
        if let open = windows[id], open.isVisible {
            window = open
        } else {
            window = SettingsWindow(contentViewController: NSHostingController(rootView: view))
            window.title = title
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            window.center()
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
enum ClearpathMain {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        app.mainMenu = shortcutMenu()
        app.run()
    }

    /// Never shown, since Clearpath has no menu bar of its own, but it gives the windows the
    /// standard shortcuts the SwiftUI app had: Cmd-W closes, Cmd-Q quits, editing keys work in fields.
    private static func shortcutMenu() -> NSMenu {
        func menu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) -> NSMenuItem {
            let submenu = NSMenu(title: title)
            for (name, action, key, flags) in items {
                submenu.addItem(withTitle: name, action: action, keyEquivalent: key).keyEquivalentModifierMask = flags
            }
            let item = NSMenuItem()
            item.submenu = submenu
            return item
        }
        let main = NSMenu()
        main.addItem(menu("Clearpath", [("Quit Clearpath", #selector(NSApplication.terminate(_:)), "q", .command)]))
        main.addItem(menu("Edit", [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]))
        main.addItem(menu("Window", [("Close", #selector(NSWindow.performClose(_:)), "w", .command)]))
        return main
    }
}
