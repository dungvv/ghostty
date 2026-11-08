import Foundation

/// Feeds a stored password to OpenSSH through its `SSH_ASKPASS` hook.
///
/// OpenSSH will not read a password from stdin; the only supported way to
/// answer its prompt without a terminal is to point `SSH_ASKPASS` at a helper
/// program and force its use. So we write a tiny shell helper once, and hand
/// the secret to it over a named pipe.
///
/// The pipe matters. Putting the password in an environment variable would
/// expose it to anything that can inspect the process, and putting it in a
/// file would leave it on disk. A FIFO in a 0700 directory, mode 0600, never
/// stores the bytes anywhere: they go straight from this process to the
/// helper's stdout and die with it.
final class SSHAskpass: @unchecked Sendable {
    /// Where the helper lives. Shared by every connection; it holds no secret.
    static var scriptPath: String {
        "\(SSHConnection.controlDirectory)/askpass.sh"
    }

    let fifoPath: String

    private let lock = NSLock()
    private var stopped = false
    private let queue = DispatchQueue(
        label: "com.mitchellh.ghostty.ssh.askpass", qos: .userInitiated)

    /// Create the helper and a private pipe for this attempt.
    init() throws {
        try SSHConnection.prepareControlDirectory()
        try Self.writeHelperScript()

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        fifoPath = "\(SSHConnection.controlDirectory)/ap-\(token)"

        unlink(fifoPath)
        guard mkfifo(fifoPath, 0o600) == 0 else {
            throw SSHProcessError.launchFailed(
                executable: "mkfifo",
                underlying: String(cString: strerror(errno)))
        }
    }

    deinit {
        stop()
    }

    /// The environment ssh needs so that it asks us rather than a terminal.
    var environment: [String: String] {
        [
            "SSH_ASKPASS": Self.scriptPath,
            // Without `force`, ssh only consults askpass when it has no tty.
            // Terminal sessions do have one, so we insist.
            "SSH_ASKPASS_REQUIRE": "force",
            "GHOSTTY_ASKPASS_FIFO": fifoPath,
            // Older OpenSSH builds refuse to use askpass with no DISPLAY set.
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
        ]
    }

    /// Start answering prompts with `secret`.
    ///
    /// Each prompt opens the pipe once, so we serve repeatedly until the
    /// attempt limit or the deadline is reached, then tear the pipe down.
    func serve(secret: String, maxAnswers: Int = 3, timeout: TimeInterval = 120) {
        let path = fifoPath
        queue.async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(timeout)
            var answered = 0

            while answered < maxAnswers, Date() < deadline, !self.isStopped {
                // O_NONBLOCK makes opening for write fail with ENXIO until a
                // reader shows up, which is what lets us honour the deadline
                // instead of blocking forever.
                let fd = open(path, O_WRONLY | O_NONBLOCK)
                if fd < 0 {
                    usleep(100_000)
                    continue
                }

                // Switch back to blocking so the write completes in one go.
                _ = fcntl(fd, F_SETFL, O_WRONLY)
                var payload = Array((secret + "\n").utf8)
                payload.withUnsafeBufferPointer { buffer in
                    var written = 0
                    while written < buffer.count {
                        let n = write(fd, buffer.baseAddress! + written, buffer.count - written)
                        if n <= 0 { break }
                        written += n
                    }
                }
                close(fd)
                answered += 1
            }

            self.stop()
        }
    }

    /// Tear down the pipe.
    ///
    /// If a helper is still blocked reading, opening and immediately closing
    /// the write end gives it EOF so it exits instead of lingering.
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }

        let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
        unlink(fifoPath)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: - Helper script

    /// The helper ssh executes. It carries no secret: it only reads the pipe
    /// whose path we pass in the environment.
    static let helperScript = """
        #!/bin/sh
        # Written by Ghostty. Answers ssh's password prompt from a private FIFO.
        # The prompt text arrives as $1; refuse anything that isn't asking for
        # a secret so we never answer a host key question with a password.
        case "$1" in
            *fingerprint*|*"yes/no"*|*"(yes/no/"*) exit 1 ;;
        esac
        [ -n "$GHOSTTY_ASKPASS_FIFO" ] || exit 1
        exec cat "$GHOSTTY_ASKPASS_FIFO"
        """

    private static func writeHelperScript() throws {
        let path = scriptPath
        let data = Data(helperScript.utf8)

        // Rewrite when missing or stale so an upgraded app can't be left
        // running an old helper.
        if let existing = FileManager.default.contents(atPath: path), existing == data {
            return
        }

        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
    }
}
