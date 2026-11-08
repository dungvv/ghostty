import AppKit

/// Opens Ghostty terminal surfaces for SSH connections.
@MainActor
enum SSHTerminalLauncher {
    /// Path to our own binary, which doubles as the `ghostty` CLI and so
    /// understands `+ssh`.
    static var ghosttyExecutable: String? {
        Bundle.main.executableURL?.path
    }

    /// Askpass helpers we've handed to running terminals.
    ///
    /// Each one serves its password for a bounded window and then shuts
    /// itself down; we hold a reference only so it isn't deallocated (and
    /// torn down) the instant we return.
    private static var activeAskpass: [SSHAskpass] = []

    /// How long a helper stays available after we launch a terminal. Long
    /// enough to cover a slow connect, short enough that a window left open
    /// isn't still able to answer prompts later.
    private static let askpassWindow: TimeInterval = 120

    /// Open a terminal running `command`. When `command` is nil we just open a
    /// normal shell in `workingDirectory`.
    ///
    /// - Parameter parentWindow: the window the new tab should join. Pass this
    ///   when the request came from a specific window (the SSH sidebar) so the
    ///   tab lands there rather than in whichever terminal was last focused.
    @discardableResult
    static func openTerminal(
        command: String? = nil,
        workingDirectory: String? = nil,
        newTab: Bool = true,
        parentWindow: NSWindow? = nil,
        environment: [String: String] = [:]
    ) -> TerminalController? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return nil }

        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.workingDirectory = workingDirectory
        config.environmentVariables = environment
        // Keep the surface around when ssh exits so a connection error stays
        // on screen instead of flashing past.
        config.waitAfterCommand = command != nil

        NSApp.activate(ignoringOtherApps: true)

        // Only ever tab onto an actual terminal window; the file browser is a
        // plain window and shouldn't become a tab host.
        let parent = parentWindow.flatMap {
            $0.windowController is TerminalController ? $0 : nil
        } ?? TerminalController.preferredParent?.window
        if newTab, let parent {
            return TerminalController.newTab(
                appDelegate.ghostty, from: parent, withBaseConfig: config)
        }
        return TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config)
    }

    /// Open an interactive ssh session for `connection`.
    ///
    /// Connections with a saved password open on a later run loop turn,
    /// because fetching from the keychain can block and must not freeze the
    /// UI. The return value is therefore nil in that case; no caller needs
    /// the controller.
    @discardableResult
    static func connect(
        _ connection: SSHConnection,
        remoteDirectory: String? = nil,
        parentWindow: NSWindow? = nil
    ) -> TerminalController? {
        SSHConnectionStore.shared.markUsed(id: connection.id)
        let command = connection.terminalCommand(
            ghosttyExecutable: ghosttyExecutable,
            remoteDirectory: remoteDirectory)

        guard connection.usesStoredPassword else {
            return openTerminal(command: command, parentWindow: parentWindow)
        }

        Task { @MainActor in
            let environment = await askpassEnvironment(for: connection)
            openTerminal(
                command: command,
                parentWindow: parentWindow,
                environment: environment)
        }
        return nil
    }

    /// Open a terminal whose only job is to authenticate so that the file
    /// browser can reuse the resulting multiplexed connection.
    @discardableResult
    static func authenticate(session: SSHSession) -> TerminalController? {
        openTerminal(command: session.interactiveAuthenticationCommand)
    }

    // MARK: - Password auth

    /// Stand up an askpass helper for `connection` and return the environment
    /// that points ssh at it. Empty when there's nothing stored.
    private static func askpassEnvironment(
        for connection: SSHConnection
    ) async -> [String: String] {
        let id = connection.id
        let secret = await Task.detached(priority: .userInitiated) {
            SSHCredentialStore.password(for: id)
        }.value

        guard let secret, !secret.isEmpty else {
            SSHProcess.logger.warning(
                "connection expects a stored password but none was found")
            return [:]
        }

        guard let helper = try? SSHAskpass() else {
            SSHProcess.logger.warning("askpass setup failed for terminal session")
            return [:]
        }

        helper.serve(secret: secret, timeout: askpassWindow)
        activeAskpass.append(helper)
        DispatchQueue.main.asyncAfter(deadline: .now() + askpassWindow + 5) {
            helper.stop()
            activeAskpass.removeAll { $0 === helper }
        }
        return helper.environment
    }
}
