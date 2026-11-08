import Foundation
import Testing
@testable import Ghostty

@Suite
struct SSHAskpassTests {
    /// Read whatever the helper would read, without blocking forever if the
    /// server never shows up.
    private func readFIFO(at path: String, timeout: TimeInterval) -> String? {
        // O_NONBLOCK lets the read end open even before a writer arrives.
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                return String(decoding: buffer[0..<n], as: UTF8.self)
            }
            usleep(50_000)
        }
        return nil
    }

    @Test
    func servesTheSecretOverThePipe() throws {
        let helper = try SSHAskpass()
        defer { helper.stop() }

        helper.serve(secret: "correct horse", maxAnswers: 1, timeout: 10)
        let delivered = readFIFO(at: helper.fifoPath, timeout: 5)

        // ssh expects a single line.
        #expect(delivered == "correct horse\n")
    }

    @Test
    func createsThePipeWithPrivatePermissions() throws {
        let helper = try SSHAskpass()
        defer { helper.stop() }

        var st = stat()
        #expect(lstat(helper.fifoPath, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFIFO)
        // Owner only: nobody else on the machine can read the password.
        #expect((st.st_mode & 0o077) == 0)
    }

    @Test
    func stopRemovesThePipe() throws {
        let helper = try SSHAskpass()
        let path = helper.fifoPath
        helper.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func writesAnExecutableHelperScript() throws {
        let helper = try SSHAskpass()
        defer { helper.stop() }

        let path = SSHAskpass.scriptPath
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(permissions & 0o077 == 0)
    }

    @Test
    func environmentPointsSSHAtTheHelper() throws {
        let helper = try SSHAskpass()
        defer { helper.stop() }

        let env = helper.environment
        #expect(env["SSH_ASKPASS"] == SSHAskpass.scriptPath)
        // Without `force`, a terminal session would prompt on its tty instead.
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env["GHOSTTY_ASKPASS_FIFO"] == helper.fifoPath)
        #expect(env["DISPLAY"] != nil)
    }

    /// The helper must not answer a host key question with the password.
    @Test(arguments: [
        "The authenticity of host 'example.com' can't be established. Key fingerprint is SHA256:abc. Are you sure you want to continue connecting (yes/no/[fingerprint])?",
        "Are you sure you want to continue connecting (yes/no)?",
    ])
    func helperRefusesHostKeyPrompts(_ prompt: String) throws {
        let helper = try SSHAskpass()
        defer { helper.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [SSHAskpass.scriptPath, prompt]
        process.environment = helper.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
    }

    @Test
    func helperRefusesWhenNoPipeIsConfigured() throws {
        let helper = try SSHAskpass()
        defer { helper.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [SSHAskpass.scriptPath, "Password:"]
        process.environment = ["GHOSTTY_ASKPASS_FIFO": ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
    }
}
