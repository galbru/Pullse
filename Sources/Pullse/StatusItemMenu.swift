import AppKit
import SwiftUI

/// The menu a right-click on the menu bar icon opens: About, Settings and Quit.
///
/// `MenuBarExtra` has no hook for a secondary click; both buttons open its window. So a
/// local event monitor picks out right-clicks (and control-clicks) that land in Pullse's
/// own status bar window, pops this menu up under the icon, and swallows the event so the
/// activity window stays shut. Left clicks pass through untouched.
@MainActor
final class StatusItemMenu: NSObject {
    private let model: AppModel
    private var monitor: Any?
    /// SwiftUI's settings opener, handed over by `MenuBarLabel` once it is on screen.
    var openSettingsAction: OpenSettingsAction?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard secondary, let button = Self.statusButton(in: event.window) else { return event }
            self.show(under: button)
            return nil
        }
    }

    /// Pullse's status item button, wherever its status bar window is.
    static func statusButton() -> NSStatusBarButton? {
        NSApp.windows.lazy.compactMap { statusButton(in: $0) }.first
    }

    /// The status item button, if `window` is the status bar window it lives in.
    private static func statusButton(in window: NSWindow?) -> NSStatusBarButton? {
        guard let window, window.className.contains("StatusBarWindow") else { return nil }
        return find(in: window.contentView)
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }

    private func show(under button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(item("About Pullse", action: #selector(about)))
        menu.addItem(item("Settings…", action: #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pullse", action: #selector(quit), key: "q"))
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        button.highlight(false)
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// The repository this build came from; builds without one get the standard panel.
    @objc private func about() {
        if let repository = model.updater.repository, let url = URL(string: "https://github.com/\(repository)") {
            NSWorkspace.shared.open(url)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
    }

    @objc private func settings() {
        NSApp.activate(ignoringOtherApps: true)
        if let openSettingsAction {
            openSettingsAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
