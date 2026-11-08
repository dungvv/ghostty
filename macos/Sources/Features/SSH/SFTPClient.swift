import Foundation

/// Talks to a remote host using the system `sftp` binary.
///
/// Every operation is a short `sftp -b -` run. That sounds expensive, but all
/// of them are multiplexed over an already authenticated `ControlMaster`
/// socket (see `SSHSession`), so a listing costs a fork and a round trip
/// rather than a fresh handshake.
///
/// We ask for `ls -lan` specifically: with the numeric flag, OpenSSH's sftp
/// renders the listing client side from the SFTP attributes instead of passing
/// through whatever string the server made up, so the format is stable no
/// matter what the remote is running.
struct SFTPClient: Sendable {
    let connection: SSHConnection
    var sftpExecutable: String = "/usr/bin/sftp"
    var sshExecutable: String = "/usr/bin/ssh"

    /// Operations that should be quick. Transfers pass `timeout: nil` to opt
    /// out entirely, which is why this is a default argument rather than a
    /// fallback inside `runBatch`.
    static let defaultTimeout: TimeInterval = 45

    // MARK: - Queries

    /// The remote home directory (where sftp starts).
    func home() async throws -> String {
        let output = try await runBatch(["pwd"])
        guard let path = Self.parseWorkingDirectory(output) else {
            throw SSHProcessError.commandFailed(
                command: "sftp pwd",
                status: 0,
                message: "Couldn't determine the remote home directory.")
        }
        return path
    }

    /// Resolve `path` (which may be relative or contain `~`) to an absolute path.
    func realpath(_ path: String) async throws -> String {
        let output = try await runBatch(["cd \(path.sftpQuoted)", "pwd"])
        guard let resolved = Self.parseWorkingDirectory(output) else { return path }
        return resolved
    }

    /// List the contents of a directory.
    func list(_ path: String) async throws -> [FileItem] {
        let output = try await runBatch(["ls -lan \(path.sftpQuoted)"])
        return Self.parseListing(output, parent: path)
    }

    // MARK: - Mutations

    func makeDirectory(_ path: String) async throws {
        try await runBatch(["mkdir \(path.sftpQuoted)"])
    }

    func rename(from: String, to: String) async throws {
        try await runBatch(["rename \(from.sftpQuoted) \(to.sftpQuoted)"])
    }

    func removeFile(_ path: String) async throws {
        try await runBatch(["rm \(path.sftpQuoted)"])
    }

    func removeEmptyDirectory(_ path: String) async throws {
        try await runBatch(["rmdir \(path.sftpQuoted)"])
    }

    func chmod(_ path: String, mode: String) async throws {
        try await runBatch(["chmod \(mode) \(path.sftpQuoted)"])
    }

    /// Recursively delete a remote directory.
    ///
    /// SFTP has no recursive remove, so this runs `rm -rf` over the same
    /// multiplexed ssh connection. The path is shell quoted and passed after
    /// `--` so a name starting with `-` can't turn into a flag.
    func removeDirectoryRecursive(_ path: String) async throws {
        let remoteCommand = "rm -rf -- \(path.shellQuoted)"
        let args = connection.sshArguments(
            controlPath: connection.controlPath,
            controlMaster: "no",
            batchMode: true,
            command: [remoteCommand])
        let result = try await SSHProcess.run(
            executable: sshExecutable,
            arguments: args,
            timeout: Self.defaultTimeout)
        guard result.succeeded else {
            throw SSHProcessError.commandFailed(
                command: "rm -rf",
                status: result.terminationStatus,
                message: result.failureMessage)
        }
    }

    // MARK: - Transfers

    /// Download `remote` to the local path `local`.
    func download(remote: String, to local: String, recursive: Bool) async throws {
        let flags = recursive ? "-rp" : "-p"
        try await runBatch(
            ["get \(flags) \(remote.sftpQuoted) \(local.sftpQuoted)"],
            timeout: nil)
    }

    /// Upload the local path `local` to `remote`.
    func upload(local: String, to remote: String, recursive: Bool) async throws {
        let flags = recursive ? "-rp" : "-p"
        try await runBatch(
            ["put \(flags) \(local.sftpQuoted) \(remote.sftpQuoted)"],
            timeout: nil)
    }

    // MARK: - Plumbing

    @discardableResult
    private func runBatch(
        _ commands: [String],
        timeout: TimeInterval? = SFTPClient.defaultTimeout
    ) async throws -> String {
        var args = ["-b", "-"]
        args += connection.sftpArguments(
            controlPath: connection.controlPath,
            controlMaster: "no",
            batchMode: true)

        let script = commands.joined(separator: "\n") + "\n"
        let result = try await SSHProcess.run(
            executable: sftpExecutable,
            arguments: args,
            standardInput: script,
            timeout: timeout)

        guard result.succeeded else {
            throw SSHProcessError.commandFailed(
                command: commands.first ?? "sftp",
                status: result.terminationStatus,
                message: result.failureMessage)
        }

        return result.standardOutput
    }

    // MARK: - Parsing

    /// sftp echoes every batch command back as `sftp> <command>`. Strip those.
    static func significantLines(_ output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("sftp> ") && !$0.isEmpty }
    }

    static func parseWorkingDirectory(_ output: String) -> String? {
        let marker = "Remote working directory: "
        for line in significantLines(output) where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    static func parseListing(_ output: String, parent: String) -> [FileItem] {
        significantLines(output).compactMap { parseListingLine($0, parent: parent) }
    }

    /// Parse one line of `ls -lan` output.
    ///
    /// The format is fixed by OpenSSH's own `ls_file()`:
    ///
    ///     drwxr-xr-x    4 501      20            128 Nov  8 10:12 Documents
    ///     \_______/  \_/ \_/      \/      \_____/ \__________/ \______/
    ///       mode    links uid    gid       size      mtime        name
    ///
    /// The first eight whitespace separated fields are fixed and everything
    /// after them is the name, which may contain spaces.
    static func parseListingLine(_ line: String, parent: String) -> FileItem? {
        var fields: [String] = []
        var rest = Substring(line)
        for _ in 0..<8 {
            while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            fields.append(String(rest[..<end]))
            rest = rest[end...]
        }
        while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }
        // sftp prints each entry relative to the *session's* working
        // directory, which is the remote home, not the directory we asked it
        // to list. Listing anywhere else therefore hands back full paths, and
        // joining those onto the parent again produced nonsense like
        // /home/me/home/me/src. A POSIX filename can never contain a slash,
        // so the last component is always the real name.
        let name = RemotePath.lastComponent(String(rest))
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let mode = fields[0]
        guard mode.count >= 10 || mode.count == 1 else { return nil }
        guard let typeChar = mode.first else { return nil }
        // Anything that isn't a recognizable mode string is noise such as
        // "Connected to host."
        guard "dl-bcps".contains(typeChar) else { return nil }

        let isSymlink = typeChar == "l"
        let isDirectory = typeChar == "d"
        let size = Int64(fields[4]) ?? 0
        let modified = parseTimestamp(month: fields[5], day: fields[6], timeOrYear: fields[7])

        return FileItem(
            name: name,
            path: RemotePath.join(parent, name),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            modified: modified,
            permissions: mode)
    }

    /// `ls` prints `MMM d HH:mm` for recent files and `MMM d  yyyy` otherwise.
    static func parseTimestamp(month: String, day: String, timeOrYear: String) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        if timeOrYear.contains(":") {
            let year = calendar.component(.year, from: Date())
            guard let date = timestampFormatter.date(
                from: "\(month) \(day) \(year) \(timeOrYear)") else { return nil }
            // A "recent" timestamp can't be in the future; if it looks like it
            // is, it belongs to last year.
            if date.timeIntervalSinceNow > 60 * 60 * 24 {
                return calendar.date(byAdding: .year, value: -1, to: date)
            }
            return date
        }
        return timestampFormatter.date(from: "\(month) \(day) \(timeOrYear) 00:00")
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMM d yyyy HH:mm"
        return f
    }()
}
