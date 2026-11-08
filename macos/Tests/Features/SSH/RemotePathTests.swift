import Foundation
import Testing
@testable import Ghostty

@Suite
struct RemotePathTests {
    @Test(arguments: [
        ("/a/b/c", "/a/b"),
        ("/a", "/"),
        ("/", "/"),
        ("/a/b/", "/a"),
    ])
    func parent(_ path: String, _ expected: String) {
        #expect(RemotePath.parent(path) == expected)
    }

    @Test(arguments: [
        ("/", "x", "/x"),
        ("/a", "b", "/a/b"),
        ("/a/", "b", "/a/b"),
    ])
    func join(_ base: String, _ component: String, _ expected: String) {
        #expect(RemotePath.join(base, component) == expected)
    }

    @Test
    func lastComponent() {
        #expect(RemotePath.lastComponent("/a/b/c") == "c")
        #expect(RemotePath.lastComponent("/a/b/") == "b")
        #expect(RemotePath.lastComponent("/") == "/")
    }

    @Test
    func breadcrumbs() {
        let crumbs = RemotePath.breadcrumbs("/usr/local/bin")
        #expect(crumbs.map(\.name) == ["/", "usr", "local", "bin"])
        #expect(crumbs.map(\.path) == ["/", "/usr", "/usr/local", "/usr/local/bin"])
    }
}
