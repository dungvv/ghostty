import Foundation
import Testing
@testable import Ghostty

@Suite
struct SSHConnectionTests {
    private func connection() -> SSHConnection {
        var c = SSHConnection(name: "Box", host: "example.com")
        c.username = "dev"
        c.port = 2222
        return c
    }

    @Test
    func buildsSSHArguments() {
        let args = connection().sshArguments(
            controlPath: "/tmp/sock", controlMaster: "yes", batchMode: true)

        #expect(args.first == "-p")
        #expect(args.contains("2222"))
        #expect(args.contains("ControlPath=/tmp/sock"))
        #expect(args.contains("ControlMaster=yes"))
        #expect(args.contains("BatchMode=yes"))
        // The destination must always come last so anything after it is read
        // as the remote command.
        #expect(args.last == "dev@example.com")
    }

    /// BatchMode disables password auth outright, so a connection that relies
    /// on a stored password must never get it, even where we ask for it.
    @Test
    func storedPasswordSuppressesBatchMode() {
        var c = connection()
        c.usesStoredPassword = true
        let args = c.sshArguments(batchMode: true)

        #expect(!args.contains("BatchMode=yes"))
        #expect(args.contains("NumberOfPasswordPrompts=1"))
    }

    @Test
    func withoutStoredPasswordBatchModeStillApplies() {
        let args = connection().sshArguments(batchMode: true)

        #expect(args.contains("BatchMode=yes"))
        #expect(!args.contains("NumberOfPasswordPrompts=1"))
    }

    @Test
    func storedPasswordFlagSurvivesACodableRoundTrip() throws {
        var c = connection()
        c.usesStoredPassword = true

        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(SSHConnection.self, from: data)
        #expect(decoded.usesStoredPassword)

        // The secret itself must never reach the file.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.lowercased().contains("\"password\""))
    }

    /// Records written before passwords existed must still decode.
    @Test
    func legacyRecordDecodesWithoutThePasswordFlag() throws {
        let data = Data("""
        {"id":"\(UUID().uuidString)","name":"Old","host":"example.com",
         "extraArguments":[],"useGhosttyWrapper":true,"group":"",
         "tags":[],"notes":""}
        """.utf8)

        let decoded = try JSONDecoder().decode(SSHConnection.self, from: data)
        #expect(decoded.usesStoredPassword == false)
    }

    /// Unknown keys from a newer build must not break an older one.
    @Test
    func unknownFieldsAreIgnored() throws {
        let data = Data("""
        {"id":"\(UUID().uuidString)","name":"Future","host":"example.com",
         "somethingWeHaveNotInventedYet":42}
        """.utf8)

        let decoded = try JSONDecoder().decode(SSHConnection.self, from: data)
        #expect(decoded.host == "example.com")
        #expect(decoded.useGhosttyWrapper)
    }

    @Test
    func sftpUsesUppercasePortFlag() {
        let args = connection().sftpArguments(controlPath: "/tmp/sock")
        #expect(args.first == "-P")
        #expect(args.last == "dev@example.com")
    }

    @Test
    func remoteCommandFollowsDestination() {
        let args = connection().sshArguments(command: ["uptime"])
        #expect(args.dropLast().last == "dev@example.com")
        #expect(args.last == "uptime")
    }

    @Test
    func terminalCommandQuotesRemoteDirectory() {
        let command = connection().terminalCommand(
            ghosttyExecutable: nil, remoteDirectory: "/srv/my app")
        #expect(command.contains("'/srv/my app'"))
        // Without the ghostty path we fall back to plain ssh.
        #expect(command.hasPrefix("'ssh'"))
        #expect(command.contains("'-t'"))
    }

    @Test
    func destinationOmitsEmptyUser() {
        var c = SSHConnection(host: "example.com")
        c.username = nil
        #expect(c.destination == "example.com")
        c.username = ""
        #expect(c.destination == "example.com")
    }

    @Test
    func displayNameFallsBackToDestination() {
        var c = SSHConnection(host: "example.com")
        #expect(c.displayName == "example.com")
        c.name = "  "
        #expect(c.displayName == "example.com")
        c.name = "Prod"
        #expect(c.displayName == "Prod")
    }

    @Test(arguments: [
        ("plain", "\"plain\""),
        ("with space", "\"with space\""),
        ("quote\"inside", "\"quote\\\"inside\""),
        ("back\\slash", "\"back\\\\slash\""),
    ])
    func sftpQuoting(_ input: String, _ expected: String) {
        #expect(input.sftpQuoted == expected)
    }

    @Test
    func shellQuotingSurvivesSingleQuotes() {
        #expect("it's".shellQuoted == "'it'\\''s'")
    }
}
