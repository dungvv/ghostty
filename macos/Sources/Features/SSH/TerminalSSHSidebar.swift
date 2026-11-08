import SwiftUI
import AppKit

/// The SSH connection list shown down the left side of a terminal window.
///
/// Double-clicking a connection opens it as a new tab in *this* window rather
/// than wherever focus happened to be, which is why the view tracks its own
/// `NSWindow`.
struct TerminalSSHSidebar: View {
    @ObservedObject var store: SSHConnectionStore

    @State private var searchText: String = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var hoveredID: UUID?
    @State private var selectedID: UUID?
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        .background(WindowAccessor(window: $hostWindow))
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Sections

    private var searchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        let groups = SSHConnection.grouped(store.connections, matching: searchText)

        if groups.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { group in
                        DisclosureGroup(isExpanded: expansion(of: group.name)) {
                            ForEach(group.connections) { connection in
                                row(connection)
                            }
                        } label: {
                            groupLabel(group)
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func groupLabel(_ group: SSHConnectionGroup) -> some View {
        HStack(spacing: 4) {
            Text(group.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            Text("\(group.connections.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func row(_ connection: SSHConnection) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(connection.displayName)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(connection.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 2)

            Button {
                openSSH(connection)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoveredID == connection.id ? Color.accentColor : Color.secondary)
            .help("Open an SSH session in a new tab")

            Button {
                openFileBrowser(connection)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoveredID == connection.id ? Color.accentColor : Color.secondary)
            .help("Open the local/remote file browser")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(rowBackground(connection))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredID = connection.id
            } else if hoveredID == connection.id {
                hoveredID = nil
            }
        }
        // The double-click handler must be declared first so SwiftUI gives it
        // a chance to claim the gesture before the single click selects.
        .onTapGesture(count: 2) {
            selectedID = connection.id
            openSSH(connection)
        }
        .onTapGesture {
            selectedID = connection.id
        }
        .contextMenu {
            Button {
                openSSH(connection)
            } label: {
                Label("Open SSH in New Tab", systemImage: "terminal")
            }
            Button {
                openFileBrowser(connection)
            } label: {
                Label("Open File Browser", systemImage: "folder")
            }
            Divider()
            Button {
                SSHConnectionManagerController.shared.show(selecting: connection.id)
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
        }
    }

    @ViewBuilder
    private func rowBackground(_ connection: SSHConnection) -> some View {
        if selectedID == connection.id {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.18))
        } else if hoveredID == connection.id {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
        } else {
            Color.clear
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(store.connections.isEmpty ? "No connections yet" : "No matches")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.connections.isEmpty {
                Button("Add Connections…") {
                    SSHConnectionManagerController.shared.show()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                SSHConnectionManagerController.shared.show()
            } label: {
                Label("Manage", systemImage: "slider.horizontal.3")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Manage SSH connections")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Actions

    private func openSSH(_ connection: SSHConnection) {
        SSHTerminalLauncher.connect(connection, parentWindow: hostWindow)
    }

    private func openFileBrowser(_ connection: SSHConnection) {
        FileBrowserController.show(for: connection)
    }

    /// Groups are expanded by default; we only remember the collapsed ones so
    /// a newly added group doesn't start hidden.
    private func expansion(of name: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(name) },
            set: { expanded in
                if expanded {
                    collapsedGroups.remove(name)
                } else {
                    collapsedGroups.insert(name)
                }
            })
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view.
///
/// This reports from `viewDidMoveToWindow` rather than the SwiftUI update
/// pass, because a view has no window yet when `updateNSView` first runs and
/// there's no guarantee of another update once it gains one.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindowChange = { newWindow in
            // Assigning during a layout pass would re-enter SwiftUI, so defer.
            DispatchQueue.main.async {
                if window !== newWindow { window = newWindow }
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {}
}

/// A view that draws nothing and reports when it joins or leaves a window.
private final class WindowReportingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
