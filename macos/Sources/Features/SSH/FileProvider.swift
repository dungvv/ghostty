import Foundation

/// The operations a file browser pane needs, whether the files live on this
/// Mac or on the other end of an SSH connection.
protocol FileProvider: Sendable {
    /// Where the pane starts when no path was configured.
    func home() async throws -> String

    /// Turn a user typed path into an absolute one.
    func resolve(_ path: String) async throws -> String

    func list(_ path: String) async throws -> [FileItem]

    func makeDirectory(at path: String) async throws

    func rename(from: String, to: String) async throws

    /// Delete a single entry, recursing into directories.
    func delete(_ item: FileItem) async throws
}

// MARK: - Local

struct LocalFileProvider: FileProvider {
    /// Run blocking filesystem work off whatever actor called us.
    ///
    /// With `NonisolatedNonsendingByDefault` (which this target enables), a
    /// plain `nonisolated async` function inherits the caller's executor, so
    /// without this hop a large directory would be enumerated on the main
    /// actor and freeze the window.
    private func offMainThread<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func home() async throws -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    func resolve(_ path: String) async throws -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = FileManager.default.currentDirectoryPath + "/" + expanded
        }
        return (expanded as NSString).standardizingPath
    }

    func list(_ path: String) async throws -> [FileItem] {
        try await offMainThread { try Self.listSync(path) }
    }

    private static func listSync(_ path: String) throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .fileResourceTypeKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [])

        return entries.map { entryURL in
            let values = try? entryURL.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink ?? false
            // A symlink pointing at a directory should be enterable, and the
            // resource values describe the link itself, so resolve those by
            // hand.
            var isDirectory = values?.isDirectory ?? false
            if isSymlink {
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &dir) {
                    isDirectory = dir.boolValue
                }
            }
            return FileItem(
                name: entryURL.lastPathComponent,
                path: entryURL.path,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                permissions: Self.modeString(for: entryURL.path))
        }
    }

    func makeDirectory(at path: String) async throws {
        try await offMainThread {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: false)
        }
    }

    func rename(from: String, to: String) async throws {
        try await offMainThread {
            try FileManager.default.moveItem(atPath: from, toPath: to)
        }
    }

    /// Local deletes go to the Trash when we can, so a misclick in a file
    /// browser isn't destructive.
    func delete(_ item: FileItem) async throws {
        let path = item.path
        try await offMainThread {
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func modeString(for path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "" }
        let mode = st.st_mode

        var result = ""
        switch mode & S_IFMT {
        case S_IFDIR: result += "d"
        case S_IFLNK: result += "l"
        case S_IFBLK: result += "b"
        case S_IFCHR: result += "c"
        case S_IFIFO: result += "p"
        case S_IFSOCK: result += "s"
        default: result += "-"
        }

        let bits: [(mode_t, String)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        for (bit, letter) in bits {
            result += (mode & bit) != 0 ? letter : "-"
        }
        return result
    }
}

// MARK: - Remote

struct RemoteFileProvider: FileProvider {
    let client: SFTPClient

    func home() async throws -> String {
        try await client.home()
    }

    func resolve(_ path: String) async throws -> String {
        try await client.realpath(path)
    }

    func list(_ path: String) async throws -> [FileItem] {
        try await client.list(path)
    }

    func makeDirectory(at path: String) async throws {
        try await client.makeDirectory(path)
    }

    func rename(from: String, to: String) async throws {
        try await client.rename(from: from, to: to)
    }

    func delete(_ item: FileItem) async throws {
        if item.isDirectory && !item.isSymlink {
            try await client.removeDirectoryRecursive(item.path)
        } else {
            try await client.removeFile(item.path)
        }
    }
}
