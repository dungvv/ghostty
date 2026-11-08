import Foundation
import Combine

/// The view model for one side of the file browser.
@MainActor
final class FilePaneModel: ObservableObject {
    enum Kind {
        case local
        case remote

        var title: String {
            switch self {
            case .local: return "Local"
            case .remote: return "Remote"
            }
        }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case name, size, modified
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size"
            case .modified: return "Date Modified"
            }
        }
    }

    let kind: Kind
    let provider: FileProvider

    /// The directory currently shown. Empty until the first load.
    @Published private(set) var path: String = ""

    /// What's in the path field. Kept separate so typing doesn't navigate.
    @Published var pathFieldText: String = ""

    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showHidden: Bool = false
    @Published var selection: Set<String> = []
    @Published var sortKey: SortKey = .name
    @Published var sortAscending: Bool = true
    @Published var filterText: String = ""

    /// Remote panes are unusable until the SSH session is up.
    @Published var isAvailable: Bool = true

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var initialPath: String?

    init(kind: Kind, provider: FileProvider, initialPath: String? = nil) {
        self.kind = kind
        self.provider = provider
        self.initialPath = initialPath
    }

    // MARK: - Derived state

    var displayedItems: [FileItem] {
        var result = items
        if !showHidden { result = result.filter { !$0.isHidden } }
        let filter = filterText.trimmingCharacters(in: .whitespaces)
        if !filter.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }

        result.sort { lhs, rhs in
            // Directories always lead, regardless of sort.
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }

            let ordered: Bool
            switch sortKey {
            case .name:
                ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                ordered = lhs.size < rhs.size
            case .modified:
                ordered = (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            }
            return sortAscending ? ordered : !ordered
        }
        return result
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { !path.isEmpty && path != "/" }

    // MARK: - Navigation

    /// Load the pane for the first time.
    func start() async {
        guard path.isEmpty else { return }
        do {
            let target: String
            if let initialPath, !initialPath.isEmpty {
                target = try await provider.resolve(initialPath)
            } else {
                target = try await provider.home()
            }
            await setPath(target, recordHistory: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigate(to newPath: String) async {
        let trimmed = newPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let resolved = try await provider.resolve(trimmed)
            await setPath(resolved, recordHistory: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ item: FileItem) async {
        guard item.isDirectory else { return }
        await setPath(item.path, recordHistory: true)
    }

    func goUp() async {
        guard canGoUp else { return }
        await setPath(RemotePath.parent(path), recordHistory: true)
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        await setPath(previous, recordHistory: false)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        await setPath(next, recordHistory: false)
    }

    func reload() async {
        guard !path.isEmpty else { return }
        await load()
    }

    private func setPath(_ newPath: String, recordHistory: Bool) async {
        if recordHistory && !path.isEmpty && path != newPath {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = newPath
        pathFieldText = newPath
        selection.removeAll()
        await load()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await provider.list(path)
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mutations

    func createDirectory(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await provider.makeDirectory(at: RemotePath.join(path, trimmed))
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ item: FileItem, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        do {
            try await provider.rename(
                from: item.path,
                to: RemotePath.join(RemotePath.parent(item.path), trimmed))
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ itemsToDelete: [FileItem]) async {
        for item in itemsToDelete {
            do {
                try await provider.delete(item)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        await load()
    }
}
