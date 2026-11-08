import Foundation
import Combine

/// Owns the multiplexed SSH connection ("control master") behind a file
/// browser window.
///
/// We authenticate exactly once, in a background `ssh -N` process, and then
/// every `sftp` or `ssh` invocation for the same connection reuses that socket
/// through `ControlPath`. That keeps directory listings fast and means we
/// never have to ask for credentials ourselves.
///
/// If non-interactive authentication fails (a password, a prompt from a
/// hardware token, a 2FA challenge), we surface the error and let the caller
/// offer to authenticate in a real terminal instead. A terminal session that
/// uses the same `ControlPath` becomes the master, and the file browser picks
/// it up on the next connect attempt.
@MainActor
final class SSHSession: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
        var isBusy: Bool { self == .connecting }

        var errorMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    let connection: SSHConnection

    @Published private(set) var state: State = .disconnected

    private var masterProcess: Process?
    private var masterErrors: SSHOutputBuffer?
    private var askpass: SSHAskpass?
    private let sshExecutable = "/usr/bin/ssh"

    /// How long we wait for the background master to come up.
    private let connectTimeout: TimeInterval = 30

    init(connection: SSHConnection) {
        self.connection = connection
    }

    var client: SFTPClient { SFTPClient(connection: connection) }

    /// The ssh command a user can run in a terminal to authenticate
    /// interactively and donate the resulting connection to us.
    var interactiveAuthenticationCommand: String {
        // Options have to come before the destination, which
        // `sshArguments` always puts last.
        var words = [sshExecutable, "-o", "ControlPersist=10m"]
        words += connection.sshArguments(
            controlPath: connection.controlPath,
            controlMaster: "auto",
            batchMode: false)
        // We keep the login shell so the user can finish any extra challenge
        // and see for themselves that the connection worked.
        return words.map { $0.shellQuoted }.joined(separator: " ")
    }

    // MARK: - Lifecycle

    func connect() async {
        guard !state.isBusy, !state.isConnected else { return }
        state = .connecting

        do {
            try SSHConnection.prepareControlDirectory()
        } catch {
            state = .failed("Couldn't create the control socket directory: \(error.localizedDescription)")
            return
        }

        // Somebody (a previous session, or a terminal the user authenticated
        // in) may already have a master running for us.
        if await isMasterAlive() {
            state = .connected
            return
        }

        var args = connection.sshArguments(
            controlPath: connection.controlPath,
            controlMaster: "yes",
            batchMode: true)
        args = [
            "-N",
            "-o", "ControlPersist=no",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ] + args

        // When a password is saved for this connection, stand up an askpass
        // helper so ssh can authenticate without a terminal.
        let environment = await prepareAskpass()

        let launched: (process: Process, errorBuffer: SSHOutputBuffer)
        do {
            launched = try SSHProcess.launch(
                executable: sshExecutable,
                arguments: args,
                environment: environment)
        } catch {
            stopAskpass()
            state = .failed(error.localizedDescription)
            return
        }
        masterProcess = launched.process
        masterErrors = launched.errorBuffer

        let deadline = Date().addingTimeInterval(connectTimeout)
        while Date() < deadline {
            if await isMasterAlive() {
                // The master holds the session now, so the password is no
                // longer needed; tear the pipe down rather than leaving it
                // open for its full window.
                stopAskpass()
                state = .connected
                return
            }

            if !launched.process.isRunning {
                let message = launched.errorBuffer.string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stopAskpass()
                masterProcess = nil
                masterErrors = nil
                state = .failed(message.isEmpty
                    ? "ssh exited before the connection was established."
                    : message)
                return
            }

            try? await Task.sleep(nanoseconds: 200 * NSEC_PER_MSEC)
        }

        // Timed out.
        launched.process.terminate()
        stopAskpass()
        masterProcess = nil
        masterErrors = nil
        state = .failed("Timed out waiting for the SSH connection.")
    }

    // MARK: - Password auth

    /// Prepare an askpass helper when this connection has a saved password.
    ///
    /// Returns the environment ssh needs, or an empty dictionary when the
    /// connection authenticates some other way.
    private func prepareAskpass() async -> [String: String] {
        stopAskpass()
        guard connection.usesStoredPassword else { return [:] }

        // Reading the keychain can block and can prompt, so keep it off the
        // main actor.
        let id = connection.id
        let secret = await Task.detached(priority: .userInitiated) {
            SSHCredentialStore.password(for: id)
        }.value

        guard let secret, !secret.isEmpty else {
            SSHProcess.logger.warning("connection expects a stored password but none was found")
            return [:]
        }

        do {
            let helper = try SSHAskpass()
            helper.serve(secret: secret)
            askpass = helper
            return helper.environment
        } catch {
            SSHProcess.logger.warning(
                "askpass setup failed error=\(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func stopAskpass() {
        askpass?.stop()
        askpass = nil
    }

    func disconnect() {
        stopAskpass()
        if let masterProcess, masterProcess.isRunning {
            masterProcess.terminate()
        }
        masterProcess = nil
        masterErrors = nil

        // Also ask any master we didn't start (for example one donated by a
        // terminal session) to go away.
        let connection = self.connection
        let executable = sshExecutable
        Task.detached {
            let args = ["-O", "exit"] + connection.sshArguments(
                controlPath: connection.controlPath,
                controlMaster: "no",
                batchMode: true)
            _ = try? await SSHProcess.run(
                executable: executable, arguments: args, timeout: 10)
        }

        state = .disconnected
    }

    /// Re-check the socket; used when a terminal session may have created one.
    func refreshConnectionState() async {
        if await isMasterAlive() {
            state = .connected
        } else if state.isConnected {
            state = .disconnected
        }
    }

    // MARK: - Private

    private func isMasterAlive() async -> Bool {
        let args = ["-O", "check"] + connection.sshArguments(
            controlPath: connection.controlPath,
            controlMaster: "no",
            batchMode: true)
        guard let result = try? await SSHProcess.run(
            executable: sshExecutable, arguments: args, timeout: 10)
        else { return false }
        return result.succeeded
    }
}
