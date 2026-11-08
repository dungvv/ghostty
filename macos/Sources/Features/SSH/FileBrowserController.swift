import AppKit
import SwiftUI

/// Window controller for the local/remote file browser.
///
/// One window per connection; asking for a connection that already has a
/// window just brings that window forward.
@MainActor
final class FileBrowserController: NSWindowController, NSWindowDelegate {
    private static var controllers: [UUID: FileBrowserController] = [:]

    let model: FileBrowserModel

    private init(connection: SSHConnection) {
        self.model = FileBrowserModel(connection: connection)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "\(connection.displayName) — Files"
        window.contentViewController = NSHostingController(
            rootView: FileBrowserView(model: model))
        window.setFrameAutosaveName("GhosttySSHFileBrowser")
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Open (or raise) the browser for `connection`.
    @discardableResult
    static func show(for connection: SSHConnection) -> FileBrowserController {
        if let existing = controllers[connection.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            Task { await existing.model.checkForDonatedConnection() }
            return existing
        }

        let controller = FileBrowserController(connection: connection)
        controllers[connection.id] = controller
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        SSHConnectionStore.shared.markUsed(id: connection.id)
        return controller
    }

    /// Close every open browser. Used at app termination so we don't leave
    /// background ssh processes behind.
    static func closeAll() {
        for controller in controllers.values {
            controller.model.shutdown()
            controller.window?.close()
        }
        controllers.removeAll()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.shutdown()
        Self.controllers.removeValue(forKey: model.connection.id)
    }
}
