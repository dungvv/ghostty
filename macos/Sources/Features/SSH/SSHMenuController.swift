import AppKit

/// Adds the SSH entries to the File and View menus and keeps the
/// "Connect to Server" submenu in sync with the saved connections.
///
/// This is done in code rather than in `MainMenu.xib` so the dynamic list of
/// connections lives next to the rest of the feature.
@MainActor
final class SSHMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = SSHMenuController()

    private var connectMenu: NSMenu?

    func install() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard let fileMenu = mainMenu.items.compactMap(\.submenu).first(where: {
            $0.title == "File"
        }) else { return }

        // Don't install twice (the menu is reloaded on some config changes).
        guard !fileMenu.items.contains(where: { $0.identifier == Self.manageItemIdentifier }) else {
            return
        }

        let connectMenu = NSMenu(title: "Connect to Server")
        connectMenu.delegate = self
        self.connectMenu = connectMenu

        let connectItem = NSMenuItem(
            title: "Connect to Server", action: nil, keyEquivalent: "")
        connectItem.submenu = connectMenu

        let manageItem = NSMenuItem(
            title: "SSH Connections…",
            action: #selector(showConnectionManager(_:)),
            keyEquivalent: "")
        manageItem.target = self
        manageItem.identifier = Self.manageItemIdentifier

        // Place these just after the "new window / new tab" group.
        let index = fileMenu.items.firstIndex(where: { $0.isSeparatorItem }).map { $0 + 1 }
            ?? fileMenu.numberOfItems
        fileMenu.insertItem(manageItem, at: index)
        fileMenu.insertItem(connectItem, at: index + 1)
        fileMenu.insertItem(.separator(), at: index + 2)

        installSidebarItem(in: mainMenu)

        // Make sure we don't leave background ssh processes running.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil)
    }

    /// Add "Show SSH Sidebar" to the View menu.
    private func installSidebarItem(in mainMenu: NSMenu) {
        guard let viewMenu = mainMenu.items.compactMap(\.submenu).first(where: {
            $0.title == "View"
        }) else { return }
        guard !viewMenu.items.contains(where: { $0.identifier == Self.sidebarItemIdentifier })
        else { return }

        let item = NSMenuItem(
            title: "Show SSH Sidebar",
            action: #selector(toggleSSHSidebar(_:)),
            keyEquivalent: "s")
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = self
        item.identifier = Self.sidebarItemIdentifier

        viewMenu.addItem(.separator())
        viewMenu.addItem(item)
    }

    // MARK: - Actions

    @objc func showConnectionManager(_ sender: Any?) {
        SSHConnectionManagerController.shared.show()
    }

    /// Toggle the sidebar on the frontmost terminal window only. This is
    /// intentionally not persisted: the configuration owns the default.
    @objc private func toggleSSHSidebar(_ sender: Any?) {
        guard let controller = TerminalController.preferredParent else { return }
        controller.sshSidebarIsVisible.toggle()
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.identifier == Self.sidebarItemIdentifier else { return true }

        // The sidebar belongs to a terminal window, so the item is dead when
        // the frontmost window isn't one (the connection manager, say).
        guard let controller = TerminalController.preferredParent else {
            menuItem.state = .off
            return false
        }

        menuItem.state = controller.sshSidebarIsVisible ? .on : .off
        return true
    }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let connection = SSHConnectionStore.shared.connection(id: id) else { return }
        SSHTerminalLauncher.connect(connection)
    }

    @objc private func browseFiles(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let connection = SSHConnectionStore.shared.connection(id: id) else { return }
        FileBrowserController.show(for: connection)
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        FileBrowserController.closeAll()
        SSHConnectionStore.shared.flush()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === connectMenu else { return }
        menu.removeAllItems()

        let connections = SSHConnectionStore.shared.connections
            .filter(\.isValid)
            .sorted { lhs, rhs in
                // Most recently used first, then alphabetical.
                switch (lhs.lastUsed, rhs.lastUsed) {
                case let (l?, r?): return l > r
                case (.some, .none): return true
                case (.none, .some): return false
                default:
                    return lhs.displayName.localizedStandardCompare(rhs.displayName)
                        == .orderedAscending
                }
            }

        if connections.isEmpty {
            let empty = NSMenuItem(title: "No Saved Connections", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for connection in connections {
                let item = NSMenuItem(
                    title: connection.displayName, action: nil, keyEquivalent: "")

                let submenu = NSMenu(title: connection.displayName)
                let terminal = NSMenuItem(
                    title: "Open Terminal",
                    action: #selector(openTerminal(_:)),
                    keyEquivalent: "")
                terminal.target = self
                terminal.representedObject = connection.id
                submenu.addItem(terminal)

                let files = NSMenuItem(
                    title: "Browse Files",
                    action: #selector(browseFiles(_:)),
                    keyEquivalent: "")
                files.target = self
                files.representedObject = connection.id
                submenu.addItem(files)

                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(
            title: "Manage Connections…",
            action: #selector(showConnectionManager(_:)),
            keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    private static let manageItemIdentifier = NSUserInterfaceItemIdentifier("GhosttySSHManage")
    private static let sidebarItemIdentifier = NSUserInterfaceItemIdentifier("GhosttySSHSidebar")
}
