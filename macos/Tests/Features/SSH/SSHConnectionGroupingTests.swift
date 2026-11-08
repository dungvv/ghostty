import Foundation
import Testing
@testable import Ghostty

@Suite
struct SSHConnectionGroupingTests {
    private func connection(
        _ name: String,
        group: String = "",
        host: String = "example.com",
        user: String? = nil,
        tags: [String] = []
    ) -> SSHConnection {
        var c = SSHConnection(name: name, host: host)
        c.group = group
        c.username = user
        c.tags = tags
        return c
    }

    @Test
    func ungroupedSortsLast() {
        let groups = SSHConnection.grouped([
            connection("a"),
            connection("b", group: "Work"),
            connection("c", group: "Alpha"),
        ])

        #expect(groups.map(\.name) == ["Alpha", "Work", SSHConnection.ungroupedName])
    }

    @Test
    func connectionsSortedWithinGroup() {
        let groups = SSHConnection.grouped([
            connection("zebra", group: "Work"),
            connection("apple", group: "Work"),
            connection("Mango", group: "Work"),
        ])

        #expect(groups.count == 1)
        #expect(groups[0].connections.map(\.displayName) == ["apple", "Mango", "zebra"])
    }

    @Test
    func blankGroupIsTreatedAsUngrouped() {
        let groups = SSHConnection.grouped([
            connection("a", group: "   "),
            connection("b"),
        ])

        #expect(groups.count == 1)
        #expect(groups[0].isUngrouped)
        #expect(groups[0].connections.count == 2)
    }

    @Test
    func groupNamesAreTrimmed() {
        let groups = SSHConnection.grouped([connection("a", group: "  Work  ")])
        #expect(groups.map(\.name) == ["Work"])
    }

    @Test
    func searchFiltersMembersAndDropsEmptyGroups() {
        let groups = SSHConnection.grouped([
            connection("prod-web", group: "Work"),
            connection("prod-db", group: "Work"),
            connection("homelab", group: "Personal"),
        ], matching: "prod")

        #expect(groups.map(\.name) == ["Work"])
        #expect(groups[0].connections.count == 2)
    }

    @Test
    func searchMatchesHostUserGroupAndTags() {
        let c = connection("box", group: "Staging", host: "web01.example.com",
                           user: "deploy", tags: ["eu-west"])

        #expect(c.matches(query: "box"))
        #expect(c.matches(query: "web01"))
        #expect(c.matches(query: "deploy"))
        #expect(c.matches(query: "staging"))
        #expect(c.matches(query: "eu-west"))
        #expect(!c.matches(query: "nothing"))
    }

    @Test
    func emptyQueryMatchesEverything() {
        let c = connection("box")
        #expect(c.matches(query: ""))
        #expect(c.matches(query: "   "))
    }

    @Test
    func searchIsCaseInsensitive() {
        let groups = SSHConnection.grouped([
            connection("Prod-Web", group: "Work"),
        ], matching: "prod-WEB")

        #expect(groups.count == 1)
    }

    @Test
    func noConnectionsYieldsNoGroups() {
        #expect(SSHConnection.grouped([]).isEmpty)
    }

    /// A connection with no name falls back to its destination, and the
    /// grouping has to sort by that same displayed string.
    @Test
    func sortsUnnamedConnectionsByDestination() {
        var a = SSHConnection(host: "zzz.example.com")
        a.group = "Work"
        var b = SSHConnection(host: "aaa.example.com")
        b.group = "Work"

        let groups = SSHConnection.grouped([a, b])
        #expect(groups[0].connections.map(\.displayName)
                == ["aaa.example.com", "zzz.example.com"])
    }
}
