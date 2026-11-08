import Foundation

/// One row in a file browser pane. The same type is used for local and remote
/// files so the two panes can share all their UI.
struct FileItem: Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: Int64
    var modified: Date?
    /// Unix mode string, e.g. `drwxr-xr-x`. Empty when unknown.
    var permissions: String

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }

    var sizeDisplay: String {
        if isDirectory { return "--" }
        return FileItem.byteFormatter.string(fromByteCount: size)
    }

    var modifiedDisplay: String {
        guard let modified else { return "" }
        return FileItem.dateFormatter.string(from: modified)
    }

    var iconName: String {
        if isSymlink { return "arrowshape.turn.up.right" }
        if isDirectory { return "folder" }
        return "doc"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// POSIX style path math. We can't use `URL` for remote paths because the
/// remote may allow characters that `URL` would percent-encode or reject.
enum RemotePath {
    static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if base == "/" { return "/" + component }
        if base.hasSuffix("/") { return base + component }
        return base + "/" + component
    }

    static func parent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard p != "/" else { return "/" }
        guard let idx = p.lastIndex(of: "/") else { return "." }
        if idx == p.startIndex { return "/" }
        return String(p[p.startIndex..<idx])
    }

    static func lastComponent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        // The root is its own last component; without this the slash would be
        // dropped and we'd return an empty name.
        guard p != "/" else { return "/" }
        guard let idx = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: idx)...])
    }

    /// Breadcrumb components, each paired with the absolute path it points at.
    static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        guard path.hasPrefix("/") else { return [(path, path)] }
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }
}
