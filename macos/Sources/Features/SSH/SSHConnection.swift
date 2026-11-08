import Foundation

/// A saved SSH/SFTP connection.
///
/// A connection is deliberately thin: it is a set of arguments we hand to the
/// system `ssh`/`sftp` binaries. Anything we don't model explicitly can be
/// expressed through `extraArguments`, and anything in the user's
/// `~/.ssh/config` still applies because we never pass `-F none`.
struct SSHConnection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// Display name. When empty we fall back to the destination.
    var name: String = ""

    /// Hostname or `~/.ssh/config` host alias.
    var host: String = ""

    /// Port. `nil` means "whatever ssh would use".
    var port: Int?

    /// Login user. `nil` means "whatever ssh would use".
    var username: String?

    /// Path to a private key (`-i`).
    var identityFile: String?

    /// Whether a password for this connection is held in the keychain.
    ///
    /// The password itself lives in `SSHCredentialStore`, never here: this
    /// file is plain JSON. The flag lets us build arguments and draw the
    /// editor without unlocking anything.
    var usesStoredPassword: Bool = false

    /// Jump host specification (`-J`), e.g. `bastion.example.com`.
    var proxyJump: String?

    /// Extra arguments passed verbatim to ssh and sftp.
    var extraArguments: [String] = []

    /// Initial remote directory for the file browser. `nil` = remote home.
    var remotePath: String?

    /// Initial local directory for the file browser. `nil` = local home.
    var localPath: String?

    /// When true, terminal sessions launch through `ghostty +ssh`, which
    /// installs Ghostty's terminfo on the remote and forwards our env vars.
    var useGhosttyWrapper: Bool = true

    /// The group this connection belongs to in the sidebar. Empty means
    /// ungrouped, which sorts last under its own heading.
    var group: String = ""

    /// Freeform labels, used for searching.
    var tags: [String] = []

    /// Freeform notes, shown in the editor only.
    var notes: String = ""

    /// Last time the user connected, used for sorting "recent".
    var lastUsed: Date?

    init(id: UUID = UUID(), name: String = "", host: String = "") {
        self.id = id
        self.name = name
        self.host = host
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, identityFile, usesStoredPassword
        case proxyJump, extraArguments, remotePath, localPath
        case useGhosttyWrapper, group, tags, notes, lastUsed
    }

    /// Decode leniently, falling back to each property's default when a key
    /// is missing.
    ///
    /// Swift's synthesized decoding does *not* apply default values: a record
    /// written before a property existed fails to decode entirely. Since the
    /// store answers a decode failure by starting empty, that would quietly
    /// delete every saved connection the first time we add a field. Reading
    /// field by field keeps old files working.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        usesStoredPassword =
            try c.decodeIfPresent(Bool.self, forKey: .usesStoredPassword) ?? false
        proxyJump = try c.decodeIfPresent(String.self, forKey: .proxyJump)
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
        remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        useGhosttyWrapper =
            try c.decodeIfPresent(Bool.self, forKey: .useGhosttyWrapper) ?? true
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }

    // MARK: - Derived

    /// What we actually pass to ssh as the destination.
    var destination: String {
        guard let username, !username.isEmpty else { return host }
        return "\(username)@\(host)"
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? destination : trimmed
    }

    /// The heading this connection appears under in the sidebar.
    var groupName: String {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? SSHConnection.ungroupedName : trimmed
    }

    /// A one line subtitle for lists.
    var subtitle: String {
        var parts: [String] = [destination]
        if let port { parts.append("port \(port)") }
        if let proxyJump, !proxyJump.isEmpty { parts.append("via \(proxyJump)") }
        return parts.joined(separator: " · ")
    }

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Does this connection match a sidebar search query?
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if displayName.localizedCaseInsensitiveContains(trimmed) { return true }
        if host.localizedCaseInsensitiveContains(trimmed) { return true }
        if (username ?? "").localizedCaseInsensitiveContains(trimmed) { return true }
        if groupName.localizedCaseInsensitiveContains(trimmed) { return true }
        return tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Where the multiplexing control socket for this connection lives.
    ///
    /// Unix socket paths are limited to ~104 bytes so we keep this short
    /// rather than using the (long) per user temporary directory.
    var controlPath: String {
        let short = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        return "\(SSHConnection.controlDirectory)/\(short)"
    }

    static var controlDirectory: String {
        "/tmp/ghostty-ssh-\(getuid())"
    }

    /// Create the control socket directory with tight permissions.
    static func prepareControlDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    // MARK: - Argument building

    /// `-o key=value` options and other flags shared by ssh and sftp.
    ///
    /// - Parameters:
    ///   - controlPath: when non-nil, multiplex over this control socket.
    ///   - controlMaster: the `ControlMaster` value to request.
    ///   - batchMode: when true, never prompt. Used for background work.
    private func sharedArguments(
        controlPath: String?,
        controlMaster: String?,
        batchMode: Bool
    ) -> [String] {
        var args: [String] = []

        if let identityFile, !identityFile.isEmpty {
            args += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        if let proxyJump, !proxyJump.isEmpty {
            args += ["-J", proxyJump]
        }
        if let controlPath {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if let controlMaster {
            args += ["-o", "ControlMaster=\(controlMaster)"]
        }
        if usesStoredPassword {
            // BatchMode disables password auth outright, so a connection that
            // relies on a stored password can never ask for it in batch mode.
            // We stay interactive and let the askpass helper answer, but cap
            // the prompts so a wrong password fails instead of looping.
            args += ["-o", "NumberOfPasswordPrompts=1"]
        } else if batchMode {
            args += ["-o", "BatchMode=yes"]
        }
        args += extraArguments
        return args
    }

    /// Arguments for the `ssh` binary (destination included).
    func sshArguments(
        controlPath: String? = nil,
        controlMaster: String? = nil,
        batchMode: Bool = false,
        command: [String] = []
    ) -> [String] {
        var args: [String] = []
        if let port { args += ["-p", String(port)] }
        args += sharedArguments(
            controlPath: controlPath,
            controlMaster: controlMaster,
            batchMode: batchMode)
        args.append(destination)
        args += command
        return args
    }

    /// Arguments for the `sftp` binary. Note sftp spells the port `-P`.
    func sftpArguments(
        controlPath: String? = nil,
        controlMaster: String? = nil,
        batchMode: Bool = true
    ) -> [String] {
        var args: [String] = []
        if let port { args += ["-P", String(port)] }
        args += sharedArguments(
            controlPath: controlPath,
            controlMaster: controlMaster,
            batchMode: batchMode)
        args.append(destination)
        return args
    }

    /// The shell command we run in a terminal surface to open this connection
    /// interactively. Every component is shell quoted.
    /// - Parameter remoteDirectory: when given, the remote shell starts there.
    func terminalCommand(
        ghosttyExecutable: String?,
        remoteDirectory: String? = nil
    ) -> String {
        var words: [String]
        if useGhosttyWrapper, let ghosttyExecutable {
            words = [ghosttyExecutable, "+ssh", "--"]
        } else {
            words = ["ssh"]
        }

        if let remoteDirectory, !remoteDirectory.isEmpty {
            // `-t` forces a pty, which we need because we're handing ssh a
            // remote command rather than letting it start a login shell.
            let remoteCommand = "cd \(remoteDirectory.shellQuoted) && exec \"$SHELL\" -l"
            words += ["-t"]
            words += sshArguments(command: [remoteCommand])
        } else {
            words += sshArguments()
        }

        return words.map { $0.shellQuoted }.joined(separator: " ")
    }
}

extension String {
    /// Quote for `/bin/sh`.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote an argument for OpenSSH's `sftp` batch command parser, which
    /// understands double quotes with backslash escapes.
    var sftpQuoted: String {
        var out = "\""
        for ch in self {
            if ch == "\\" || ch == "\"" { out.append("\\") }
            out.append(ch)
        }
        out.append("\"")
        return out
    }
}

// MARK: - Grouping

/// A sidebar section: a group heading and the connections under it.
struct SSHConnectionGroup: Identifiable, Hashable {
    let name: String
    let connections: [SSHConnection]

    var id: String { name }
    var isUngrouped: Bool { name == SSHConnection.ungroupedName }
}

extension SSHConnection {
    /// The heading used for connections with no group set.
    static let ungroupedName = "Ungrouped"

    /// Arrange connections into sidebar sections.
    ///
    /// Named groups come first in alphabetical order and the ungrouped
    /// section always sorts last, so adding a connection without a group
    /// never pushes the user's own groups around. Connections inside a group
    /// are sorted by display name. Empty groups are dropped, which matters
    /// when a search filters every member out.
    static func grouped(
        _ connections: [SSHConnection],
        matching query: String = ""
    ) -> [SSHConnectionGroup] {
        let matching = connections.filter { $0.matches(query: query) }
        let byGroup = Dictionary(grouping: matching) { $0.groupName }

        return byGroup
            .map { name, members in
                SSHConnectionGroup(
                    name: name,
                    connections: members.sorted {
                        $0.displayName.localizedStandardCompare($1.displayName)
                            == .orderedAscending
                    })
            }
            .sorted { lhs, rhs in
                if lhs.isUngrouped != rhs.isUngrouped { return rhs.isUngrouped }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
