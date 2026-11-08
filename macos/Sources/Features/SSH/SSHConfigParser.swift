import Foundation

/// A single `Host` block read out of an OpenSSH client config file.
struct SSHConfigHost {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?

    /// Convert to a connection we can save. We keep the alias as the host so
    /// that ssh keeps applying the rest of the user's config for it.
    func makeConnection() -> SSHConnection {
        var c = SSHConnection(name: alias, host: alias)
        c.username = user
        c.port = port
        c.identityFile = identityFile
        c.proxyJump = proxyJump
        return c
    }
}

/// A deliberately small reader for `~/.ssh/config`.
///
/// We only understand enough to offer an import: `Host` blocks and the handful
/// of keywords we model. Everything else still works at connect time because
/// ssh reads the same file itself.
enum SSHConfigParser {
    static var defaultPath: String {
        (("~/.ssh/config") as NSString).expandingTildeInPath
    }

    /// Parse `path`, following `Include` directives one level deep.
    static func parse(path: String = defaultPath) -> [SSHConfigHost] {
        var seen = Set<String>()
        return parse(path: path, visited: &seen)
    }

    private static func parse(path: String, visited: inout Set<String>) -> [SSHConfigHost] {
        let resolved = (path as NSString).expandingTildeInPath
        guard !visited.contains(resolved) else { return [] }
        visited.insert(resolved)
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return []
        }

        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost?

        func flush() {
            if let current, !current.alias.isEmpty { hosts.append(current) }
            current = nil
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Keywords may be separated from their argument by whitespace or
            // by an equals sign.
            let separators = CharacterSet(charactersIn: " \t=")
            let parts = line.split(whereSeparator: { separators.contains($0.unicodeScalars.first!) })
            guard let keywordPart = parts.first else { continue }
            let keyword = keywordPart.lowercased()
            let value = parts.dropFirst().map(String.init)
            let firstValue = value.first.map(unquote)

            switch keyword {
            case "host":
                flush()
                // Skip pattern-only blocks (`Host *`); there's nothing to
                // connect to and the settings apply to everything anyway.
                let aliases = value.map(unquote).filter {
                    !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!")
                }
                if let alias = aliases.first {
                    current = SSHConfigHost(alias: alias)
                }

            case "match":
                // We can't evaluate Match conditions, so stop attributing
                // keywords to the previous host.
                flush()

            case "hostname":
                current?.hostName = firstValue
            case "user":
                current?.user = firstValue
            case "port":
                current?.port = firstValue.flatMap { Int($0) }
            case "identityfile":
                if current?.identityFile == nil { current?.identityFile = firstValue }
            case "proxyjump":
                current?.proxyJump = firstValue

            case "include":
                flush()
                for pattern in value.map(unquote) {
                    for included in expandIncludePaths(pattern) {
                        hosts += parse(path: included, visited: &visited)
                    }
                }

            default:
                break
            }
        }

        flush()
        return hosts
    }

    private static func unquote(_ s: String) -> String {
        var out = s
        if out.count >= 2, out.hasPrefix("\""), out.hasSuffix("\"") {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }

    /// Resolve an `Include` argument, which may be relative to `~/.ssh` and
    /// may contain a glob.
    private static func expandIncludePaths(_ pattern: String) -> [String] {
        var p = (pattern as NSString).expandingTildeInPath
        if !p.hasPrefix("/") {
            p = (("~/.ssh") as NSString).expandingTildeInPath + "/" + p
        }

        guard p.contains("*") || p.contains("?") else { return [p] }

        let directory = (p as NSString).deletingLastPathComponent
        let globPattern = (p as NSString).lastPathComponent
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { fnmatch(globPattern, $0, 0) == 0 }
            .sorted()
            .map { directory + "/" + $0 }
    }
}
