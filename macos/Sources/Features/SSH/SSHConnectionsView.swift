import SwiftUI
import AppKit

/// The SSH connection manager: a list of saved connections on the left and an
/// editor for the selected one on the right.
struct SSHConnectionsView: View {
    @ObservedObject var store: SSHConnectionStore

    /// Selection lives outside the view so the window controller can focus a
    /// specific connection, e.g. when "Edit…" is chosen in the sidebar.
    @ObservedObject var selectionModel: SSHConnectionsSelection
    @State private var searchText: String = ""
    @State private var statusMessage: String?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
            detail
                .frame(minWidth: 420)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selectionModel.selection) {
                ForEach(filteredConnections) { connection in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connection.displayName)
                            .lineLimit(1)
                        Text(connection.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .tag(connection.id)
                    .contextMenu {
                        Button("Open Terminal") { SSHTerminalLauncher.connect(connection) }
                        Button("Browse Files") { FileBrowserController.show(for: connection) }
                        Divider()
                        Button("Duplicate") {
                            if let copy = store.duplicate(id: connection.id) {
                                selectionModel.selection = copy.id
                            }
                        }
                        Button(role: .destructive) {
                            store.remove(ids: [connection.id])
                            if selectionModel.selection == connection.id {
                                selectionModel.selection = nil
                            }
                        } label: {
                            Text("Delete")
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 4) {
                Button {
                    var connection = SSHConnection(name: "New Connection")
                    connection.host = ""
                    store.add(connection)
                    selectionModel.selection = connection.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a connection")

                Button {
                    guard let selection = selectionModel.selection else { return }
                    store.remove(ids: [selection])
                    selectionModel.selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .help("Remove the selected connection")
                .disabled(selectionModel.selection == nil)

                Button {
                    let added = store.importFromSSHConfig()
                    statusMessage = added == 0
                        ? "No new hosts found in ~/.ssh/config."
                        : "Imported \(added) host\(added == 1 ? "" : "s") from ~/.ssh/config."
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import hosts from ~/.ssh/config")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection = selectionModel.selection,
           let binding = connectionBinding(selection) {
            SSHConnectionEditorView(connection: binding)
                .id(selection)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select a connection")
                    .foregroundStyle(.secondary)
                Text("Or import your existing hosts from ~/.ssh/config.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var filteredConnections: [SSHConnection] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let base = store.connections.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || ($0.username ?? "").localizedCaseInsensitiveContains(query)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func connectionBinding(_ id: UUID) -> Binding<SSHConnection>? {
        guard store.connections.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                store.connections.first { $0.id == id } ?? SSHConnection()
            },
            set: { newValue in
                guard let idx = store.connections.firstIndex(where: { $0.id == id }) else { return }
                store.connections[idx] = newValue
            })
    }
}

/// The connection manager's current selection, owned by the window controller.
@MainActor
final class SSHConnectionsSelection: ObservableObject {
    @Published var selection: UUID?
}
