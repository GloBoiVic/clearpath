import AppKit
import SwiftUI

/// A borderless panel that closes on Escape or Cmd-W and can take keyboard focus.
final class MenuBarPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func performClose(_ sender: Any?) { orderOut(nil) }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onClose?()
    }
}

/// A settings window. Escape has nothing to cancel here, so it is ignored instead of
/// playing the alert sound. Cmd-W closes, as in other Mac windows.
final class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // Escape still reaches a field that is composing text (an input method's marked text).
        let composing = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil, !composing { return }
        super.sendEvent(event)
    }

    /// The settings screens are scrolling forms with no natural height, so the window starts
    /// at least `height` tall. Its width is fixed by the view; it can be resized taller or shorter.
    static func make<Content: View>(_ title: String, _ view: Content, height: CGFloat = 480) -> SettingsWindow {
        let controller = NSHostingController(rootView: view)
        let fitting = controller.view.fittingSize  // measured before sizingOptions, which make it zero
        controller.sizingOptions = [.minSize, .maxSize]
        let window = SettingsWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: fitting.width, height: max(fitting.height, height)))
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// Owns the shield in the menu bar, the panel it opens and the app's windows.
/// AppKit replaces SwiftUI's MenuBarExtra, which always drops its panel straight below the icon.
@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let health = ProtectionHealth()
    private let siteBlocks = SiteBlockModel()
    private let blockedLookupNotifications = BlockedLookupNotifications()
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var hosting: NSHostingView<Panel>!
    private var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        blockedLookupNotifications.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown])
        }

        hosting = NSHostingView(rootView: Panel(
            health: health,
            siteBlocks: siteBlocks,
            openBlockSite: { [unowned self] in show("block-site", "Block a site", BlockSiteView(model: siteBlocks)) },
            openBlockedSites: { [unowned self] in show("blocked-sites", "Blocked sites", BlockedSitesView(model: siteBlocks)) },
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
        health.onStateChange = { [weak self] in self?.protectionStateChanged() }
        protectionStateChanged()
        Task { [health] in
            while !Task.isCancelled {
                await health.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); return }
        guard positionPanel() else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        statusItem.button?.highlight(true)
        Task {
            async let protection: Void = health.refresh()
            async let removals: Void = siteBlocks.refreshRequests()
            _ = await (protection, removals)
        }
    }

    private func protectionStateChanged() {
        statusItem.button?.image = shieldImage(for: health.state)
        statusItem.button?.setAccessibilityLabel("Clearpath. \(health.state.headline). See Partner settings for partner status.")
        // SwiftUI recomputes the panel's height when recovery guidance appears or disappears.
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            _ = positionPanel()
            panel.invalidateShadow()
        }
    }

    @discardableResult
    private func positionPanel() -> Bool {
        guard let button = statusItem.button, let barWindow = button.window,
              let screen = barWindow.screen ?? NSScreen.main else { return false }
        let icon = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hosting.fittingSize
        panel.setFrame(NSRect(origin: panelOrigin(icon: icon, panel: size, screen: screen.visibleFrame), size: size),
                       display: panel.isVisible)
        return true
    }

    // Clicking anywhere outside the panel, including another app, takes focus from it.
    func windowDidResignKey(_ notification: Notification) {
        if panel.attachedSheet == nil { panel.orderOut(nil) }
    }

    private func show<Content: View>(_ id: String, _ title: String, _ view: Content) {
        panel.orderOut(nil)
        // A closed window is rebuilt so its view loads fresh, as SwiftUI's Window scene did.
        let window: NSWindow
        if let open = windows[id], open.isVisible || open.isMiniaturized {
            window = open
            open.deminiaturize(nil)
        } else {
            window = SettingsWindow.make(title, view)
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@main
@MainActor
enum ClearpathMain {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        app.mainMenu = shortcutMenu()
        // The app holds its delegate weakly, so keep the controller alive for the whole run.
        withExtendedLifetime(controller) { app.run() }
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
