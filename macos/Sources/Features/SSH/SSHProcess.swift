import Foundation
import OSLog

/// The result of running a subprocess.
struct SSHProcessResult {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { terminationStatus == 0 }

    /// A human readable failure message, preferring stderr but falling back to
    /// stdout since some tools write diagnostics to stdout.
    var failureMessage: String {
        let err = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "Command exited with status \(terminationStatus)."
    }
}

enum SSHProcessError: LocalizedError {
    case launchFailed(executable: String, underlying: String)
    case commandFailed(command: String, status: Int32, message: String)
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let underlying):
            return "Couldn't run \(executable): \(underlying)"
        case .commandFailed(let command, _, let message):
            return "\(command) failed: \(message)"
        case .timedOut(let command):
            return "\(command) timed out."
        }
    }
}

/// Small helper for running `ssh`, `sftp` and friends off the main thread.
///
/// Everything in the SSH feature shells out to the system OpenSSH binaries.
/// That means we inherit the user's `~/.ssh/config`, their agent, their keys
/// and their hardware tokens for free, and we never have to handle a password
/// ourselves.
enum SSHProcess {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "ssh"
    )

    /// Concurrent queue used to block on process I/O without tying up the
    /// cooperative thread pool for too long.
    private static let queue = DispatchQueue(
        label: "com.mitchellh.ghostty.ssh.process",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Run `executable` with `arguments`, optionally feeding `standardInput`
    /// to its stdin, and wait for it to exit.
    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval? = nil,
        environment: [String: String] = [:]
    ) async throws -> SSHProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try runSync(
                        executable: executable,
                        arguments: arguments,
                        standardInput: standardInput,
                        timeout: timeout,
                        environment: environment)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Launch a long lived process. The caller owns the returned process and
    /// is responsible for terminating it. stderr is captured into the returned
    /// buffer object so that we can show an error if it dies early.
    static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (process: Process, errorBuffer: SSHOutputBuffer) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = inheritedEnvironment(adding: environment)

        let errorBuffer = SSHOutputBuffer()
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errorBuffer.append(data)
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw SSHProcessError.launchFailed(
                executable: executable,
                underlying: error.localizedDescription)
        }

        return (process, errorBuffer)
    }

    // MARK: - Private

    private static func runSync(
        executable: String,
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval?,
        environment: [String: String]
    ) throws -> SSHProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = inheritedEnvironment(adding: environment)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inPipe = nil
        }

        do {
            try process.run()
        } catch {
            throw SSHProcessError.launchFailed(
                executable: executable,
                underlying: error.localizedDescription)
        }

        // Feed stdin on its own thread so a large batch script can't deadlock
        // against a full stdout pipe.
        if let inPipe, let standardInput {
            queue.async {
                let handle = inPipe.fileHandleForWriting
                if let data = standardInput.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
                try? handle.close()
            }
        }

        let group = DispatchGroup()
        let outBuffer = SSHOutputBuffer()
        let errBuffer = SSHOutputBuffer()

        group.enter()
        queue.async {
            outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        queue.async {
            errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        var timedOut = false
        var timeoutWork: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOut = true
                process.terminate()
                // Give it a moment to die politely, then insist.
                queue.asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            timeoutWork = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }

        process.waitUntilExit()
        timeoutWork?.cancel()
        group.wait()

        if timedOut {
            throw SSHProcessError.timedOut(
                command: ([executable] + arguments).joined(separator: " "))
        }

        return SSHProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outBuffer.string,
            standardError: errBuffer.string)
    }

    /// The environment our child processes get.
    ///
    /// We start from the app's own environment and drop any askpass settings
    /// we inherited, so a stray `SSH_ASKPASS` from the user's shell can't
    /// pop an unexpected dialog. `extra` is then layered on top, which is how
    /// `SSHAskpass` installs the helper we *do* control.
    private static func inheritedEnvironment(
        adding extra: [String: String] = [:]
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SSH_ASKPASS")
        env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        for (key, value) in extra { env[key] = value }
        return env
    }
}

/// A tiny thread safe byte buffer. `Pipe` handlers come in on arbitrary
/// queues so we need the lock.
final class SSHOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
