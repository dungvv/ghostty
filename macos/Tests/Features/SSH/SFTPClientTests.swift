import Foundation
import Testing
@testable import Ghostty

@Suite
struct SFTPClientTests {
    /// A listing exactly as OpenSSH's `sftp` renders it for `ls -lan`, with
    /// the command echo and banner it mixes into stdout.
    private let listing = """
    sftp> ls -lan "/Users/test"
    Connected to host.
    drwxr-xr-x    5 501      20            160 Nov  8 10:12 Documents
    -rw-r--r--    1 501      20           1234 Jan 13  2024 notes.txt
    lrwxr-xr-x    1 501      20              7 Feb  2 09:00 link
    -rw-r--r--    1 501      20             42 Nov  8 10:12 my file with spaces.txt
    drwxr-xr-x    2 0        0              64 Nov  8 10:12 .
    drwxr-xr-x    9 0        0             288 Nov  8 10:12 ..
    """

    @Test
    func parsesListing() {
        let items = SFTPClient.parseListing(listing, parent: "/Users/test")

        // `.` and `..` are dropped, as are the echo and banner lines.
        #expect(items.count == 4)
        #expect(items.map(\.name) == [
            "Documents", "notes.txt", "link", "my file with spaces.txt",
        ])
    }

    @Test
    func parsesFileTypes() {
        let items = SFTPClient.parseListing(listing, parent: "/Users/test")
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(byName["Documents"]?.isDirectory == true)
        #expect(byName["notes.txt"]?.isDirectory == false)
        #expect(byName["link"]?.isSymlink == true)
    }

    @Test
    func parsesSizesAndPaths() {
        let items = SFTPClient.parseListing(listing, parent: "/Users/test")
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(byName["notes.txt"]?.size == 1234)
        #expect(byName["my file with spaces.txt"]?.path
                == "/Users/test/my file with spaces.txt")
    }

    /// sftp reports names relative to the session's working directory, so
    /// listing anything other than the remote home comes back as full paths.
    /// Joining those onto the parent again doubled the directory.
    @Test
    func stripsFullPathsFromEntryNames() {
        let listing = """
        sftp> ls -lan "/home/me/src"
        drwxr-xr-x    4 501      20            128 Nov  8 10:12 /home/me/src/app
        -rw-r--r--    1 501      20            512 Nov  8 10:12 /home/me/src/main.c
        """

        let items = SFTPClient.parseListing(listing, parent: "/home/me/src")

        #expect(items.map(\.name) == ["app", "main.c"])
        #expect(items.map(\.path) == ["/home/me/src/app", "/home/me/src/main.c"])
    }

    /// Entering a subdirectory used to build parent + full path.
    @Test
    func pathsStayCorrectForNestedDirectories() {
        let listing = """
        drwxr-xr-x    2 501      20             64 Nov  8 10:12 /home/me/src/app/assets
        """

        let items = SFTPClient.parseListing(listing, parent: "/home/me/src/app")

        #expect(items.count == 1)
        #expect(items[0].path == "/home/me/src/app/assets")
        #expect(!items[0].path.contains("/home/me/src/app/home"))
    }

    @Test
    func keepsPlainNamesUntouched() {
        let listing = """
        -rw-r--r--    1 501      20            512 Nov  8 10:12 notes.txt
        """

        let items = SFTPClient.parseListing(listing, parent: "/home/me")
        #expect(items.map(\.name) == ["notes.txt"])
        #expect(items.map(\.path) == ["/home/me/notes.txt"])
    }

    @Test
    func stripsDotEntriesGivenAsFullPaths() {
        let listing = """
        drwxr-xr-x    2 501      20             64 Nov  8 10:12 /home/me/src/.
        drwxr-xr-x    9 501      20            288 Nov  8 10:12 /home/me/src/..
        """

        #expect(SFTPClient.parseListing(listing, parent: "/home/me/src").isEmpty)
    }

    @Test
    func rejectsLinesThatArentListings() {
        #expect(SFTPClient.parseListingLine("Connected to host.", parent: "/") == nil)
        #expect(SFTPClient.parseListingLine("", parent: "/") == nil)
        #expect(SFTPClient.parseListingLine("garbage", parent: "/") == nil)
    }

    @Test
    func parsesWorkingDirectory() {
        let output = "sftp> pwd\nRemote working directory: /home/dev\n"
        #expect(SFTPClient.parseWorkingDirectory(output) == "/home/dev")
        #expect(SFTPClient.parseWorkingDirectory("sftp> pwd\n") == nil)
    }

    @Test
    func parsesTimestampWithTime() throws {
        let date = try #require(SFTPClient.parseTimestamp(
            month: "Jan", day: "13", timeOrYear: "09:30"))
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.month, .day, .hour, .minute], from: date)
        #expect(components.month == 1)
        #expect(components.day == 13)
        #expect(components.hour == 9)
        #expect(components.minute == 30)
    }

    @Test
    func parsesTimestampWithYear() throws {
        let date = try #require(SFTPClient.parseTimestamp(
            month: "Jan", day: "13", timeOrYear: "2024"))
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        #expect(year == 2024)
    }

    /// A `ls` timestamp without a year never refers to the future, so a date
    /// that would land ahead of now belongs to the previous year.
    @Test
    func recentTimestampNeverLandsInTheFuture() throws {
        let calendar = Calendar(identifier: .gregorian)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 2, to: Date()))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        let month = formatter.string(from: tomorrow)
        let day = String(calendar.component(.day, from: tomorrow))

        let parsed = try #require(SFTPClient.parseTimestamp(
            month: month, day: day, timeOrYear: "12:00"))
        #expect(parsed < Date())
    }
}
