import Foundation
import OSLog
import Combine

/// Persistent list of the user's saved SSH connections.
///
/// Stored as JSON next to the rest of our application support data so it is
/// easy to inspect, back up or sync. Nothing secret is ever written here: we
/// store hostnames and paths to key files, never passwords or key material.
@MainActor
final class SSHConnectionStore: ObservableObject {
    static let shared = SSHConnectionStore()

    @Published var connections: [SSHConnection] = [] {
        didSet { scheduleSave() }
    }

    private var saveWorkItem: DispatchWorkItem?

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("ssh-connections.json")
    }

    init(load: Bool = true) {
        if load { self.connections = Self.loadFromDisk() }
    }

    // MARK: - Mutations

    func add(_ connection: SSHConnection) {
        connections.append(connection)
    }

    func update(_ connection: SSHConnection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx] = connection
    }

    func remove(ids: Set<UUID>) {
        // Drop any saved passwords with the connections, so deleting one
        // doesn't leave an orphaned keychain item behind.
        for id in ids where connections.contains(where: { $0.id == id && $0.usesStoredPassword }) {
            SSHCredentialStore.removePassword(for: id)
        }
        connections.removeAll { ids.contains($0.id) }
    }

    func duplicate(id: UUID) -> SSHConnection? {
        guard let original = connections.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        // Keychain items are keyed by connection id, so the copy starts
        // without a password rather than silently pointing at nothing.
        copy.usesStoredPassword = false
        copy.name = original.displayName + " copy"
        copy.lastUsed = nil
        connections.append(copy)
        return copy
    }

    func markUsed(id: UUID) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[idx].lastUsed = Date()
    }

    func connection(id: UUID) -> SSHConnection? {
        connections.first { $0.id == id }
    }

    /// All tags currently in use, sorted.
    var allTags: [String] {
        Array(Set(connections.flatMap(\.tags))).sorted()
    }

    /// Import hosts from the user's `~/.ssh/config`.
    ///
    /// Hosts we already have (matched by host alias) are skipped so repeated
    /// imports are safe.
    @discardableResult
    func importFromSSHConfig(path: String = SSHConfigParser.defaultPath) -> Int {
        let existing = Set(connections.map { $0.host.lowercased() })
        var added = 0
        for host in SSHConfigParser.parse(path: path) {
            guard !existing.contains(host.alias.lowercased()) else { continue }
            var connection = host.makeConnection()
            connection.group = "ssh_config"
            connection.tags = ["ssh_config"]
            connections.append(connection)
            added += 1
        }
        return added
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = connections
        let work = DispatchWorkItem { Self.save(snapshot) }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Write immediately. Used when the app is terminating.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        Self.save(connections)
    }

    private static func save(_ connections: [SSHConnection]) {
        let url = storeURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(connections)
            try data.write(to: url, options: .atomic)
        } catch {
            SSHProcess.logger.warning(
                "failed to save ssh connections error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadFromDisk() -> [SSHConnection] {
        let url = storeURL
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SSHConnection].self, from: data)
        } catch {
            // Starting empty would be silently destructive: the next save
            // would overwrite whatever we failed to read. Move the file aside
            // so the user still has their connections.
            SSHProcess.logger.error(
                "failed to load ssh connections error=\(error.localizedDescription, privacy: .public)")
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            SSHProcess.logger.error(
                "moved unreadable connection store to \(backup.lastPathComponent, privacy: .public)")
            return []
        }
    }
}
