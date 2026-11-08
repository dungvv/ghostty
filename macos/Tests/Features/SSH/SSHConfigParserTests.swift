import Foundation
import Testing
@testable import Ghostty

@Suite
struct SSHConfigParserTests {
    /// Write `contents` to a temporary file and parse it.
    private func parse(_ contents: String) throws -> [SSHConfigHost] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-ssh-config-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return SSHConfigParser.parse(path: url.path)
    }

    @Test
    func readsHostBlocks() throws {
        let hosts = try parse("""
        Host prod
            HostName prod.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/prod_ed25519

        Host staging
            HostName staging.example.com
        """)

        #expect(hosts.count == 2)
        #expect(hosts[0].alias == "prod")
        #expect(hosts[0].hostName == "prod.example.com")
        #expect(hosts[0].user == "deploy")
        #expect(hosts[0].port == 2222)
        #expect(hosts[0].identityFile == "~/.ssh/prod_ed25519")
        #expect(hosts[1].alias == "staging")
        #expect(hosts[1].user == nil)
    }

    @Test
    func skipsWildcardBlocks() throws {
        let hosts = try parse("""
        Host *
            ServerAliveInterval 60

        Host real
            HostName real.example.com
        """)

        #expect(hosts.map(\.alias) == ["real"])
    }

    @Test
    func stopsAttributingKeywordsAfterMatch() throws {
        let hosts = try parse("""
        Host prod
            HostName prod.example.com

        Match host something
            User nobody
        """)

        #expect(hosts.count == 1)
        #expect(hosts[0].user == nil)
    }

    @Test
    func acceptsEqualsSeparators() throws {
        let hosts = try parse("""
        Host prod
            HostName=prod.example.com
            User=deploy
        """)

        #expect(hosts[0].hostName == "prod.example.com")
        #expect(hosts[0].user == "deploy")
    }

    @Test
    func ignoresCommentsAndBlankLines() throws {
        let hosts = try parse("""
        # a comment

        Host prod
            # another comment
            HostName prod.example.com
        """)

        #expect(hosts.count == 1)
        #expect(hosts[0].hostName == "prod.example.com")
    }

    @Test
    func keepsAliasAsHostSoSSHConfigStillApplies() throws {
        let hosts = try parse("""
        Host prod
            HostName prod.example.com
            User deploy
        """)

        let connection = hosts[0].makeConnection()
        #expect(connection.host == "prod")
        #expect(connection.username == "deploy")
    }

    @Test
    func missingFileYieldsNoHosts() {
        #expect(SSHConfigParser.parse(path: "/nonexistent/ssh/config").isEmpty)
    }
}
