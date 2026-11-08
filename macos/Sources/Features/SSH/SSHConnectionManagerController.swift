import AppKit
import SwiftUI

/// Window controller for the SSH connection manager.
@MainActor
final class SSHConnectionManagerController: NSWindowController {
    static let shared = SSHConnectionManagerController()

    private let selectionModel: SSHConnectionsSelection

    private init() {
        // Held in a local as well because `self` isn't available until after
        // `super.init`, and the root view needs it now.
        let selectionModel = SSHConnectionsSelection()
        self.selectionModel = selectionModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "SSH Connections"
        window.contentViewController = NSHostingController(
            rootView: SSHConnectionsView(
                store: SSHConnectionStore.shared,
                selectionModel: selectionModel))
        window.setFrameAutosaveName("GhosttySSHConnections")
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Show the manager, optionally focusing a particular connection.
    func show(selecting id: UUID? = nil) {
        if let id { selectionModel.selection = id }
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
