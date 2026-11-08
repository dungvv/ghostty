import SwiftUI
import AppKit

/// One side of the dual pane file browser.
struct FilePaneView: View {
    @ObservedObject var model: FilePaneModel

    /// Title shown in the pane header, e.g. "This Mac" or "user@host".
    let subtitle: String

    /// Label for the transfer button, e.g. "Upload" or "Download".
    let transferTitle: String
    let transferSymbol: String

    /// Called with the current selection when the user asks to transfer.
    let onTransfer: ([FileItem]) -> Void

    /// Called when the user wants a terminal in the shown directory.
    let onOpenTerminal: (String) -> Void

    @State private var newFolderName: String = ""
    @State private var isShowingNewFolder = false
    @State private var renameTarget: FileItem?
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pathBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 320)
        .alert("New Folder", isPresented: $isShowingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.createDirectory(named: name) }
            }
        } message: {
            Text("Create a folder in \(model.path).")
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                guard let target = renameTarget else { return }
                let name = renameText
                renameTarget = nil
                Task { await model.rename(target, to: name) }
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(deleteButtonTitle, role: .destructive) {
                let targets = model.selectedItems
                Task { await model.delete(targets) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.kind == .local
                 ? "Items are moved to the Trash when possible."
                 : "Remote deletions are permanent and cannot be undone.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: model.kind == .local ? "laptopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.kind.title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var pathBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    Task { await model.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .disabled(!model.canGoBack)

                Button {
                    Task { await model.goUp() }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Enclosing folder")
                .disabled(!model.canGoUp)

                TextField("Path", text: $model.pathFieldText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        let target = model.pathFieldText
                        Task { await model.navigate(to: target) }
                    }

                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button {
                    isShowingNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New folder")
            }

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $model.filterText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Toggle("Hidden", isOn: $model.showHidden)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show hidden files")

                Menu {
                    Picker("Sort by", selection: $model.sortKey) {
                        ForEach(FilePaneModel.SortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Ascending", isOn: $model.sortAscending)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .disabled(!model.isAvailable)
    }

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable {
            unavailableView
        } else {
            ZStack {
                List(model.displayedItems, selection: $model.selection) { item in
                    row(item)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if item.isDirectory {
                                Task { await model.open(item) }
                            } else {
                                onTransfer([item])
                            }
                        }
                        .contextMenu {
                            contextMenu(for: item)
                        }
                }
                .listStyle(.inset)

                if let errorMessage = model.errorMessage {
                    errorOverlay(errorMessage)
                }
            }
        }
    }

    private func row(_ item: FileItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconName)
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.sizeDisplay)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(item.modifiedDisplay)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        if item.isDirectory {
            Button("Open") { Task { await model.open(item) } }
        }
        Button {
            onTransfer(targets(including: item))
        } label: {
            Label("\(transferTitle) \"\(item.name)\"", systemImage: transferSymbol)
        }
        Divider()
        Button("Rename…") {
            renameTarget = item
            renameText = item.name
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if model.kind == .local {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
        Divider()
        Button {
            onOpenTerminal(item.isDirectory ? item.path : RemotePath.parent(item.path))
        } label: {
            Label("Open Terminal Here", systemImage: "terminal")
        }
        Divider()
        Button(role: .destructive) {
            if !model.selection.contains(item.id) {
                model.selection = [item.id]
            }
            isConfirmingDelete = true
        } label: {
            Text("Delete…")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onTransfer(model.selectedItems)
            } label: {
                Label(transferTitle, systemImage: transferSymbol)
            }
            .disabled(model.selection.isEmpty || !model.isAvailable)

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty || !model.isAvailable)

            Spacer()

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Not connected")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    model.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
        }
    }

    // MARK: - Helpers

    /// If the clicked item isn't part of the selection, act on it alone.
    private func targets(including item: FileItem) -> [FileItem] {
        model.selection.contains(item.id) ? model.selectedItems : [item]
    }

    private var statusText: String {
        let shown = model.displayedItems.count
        if model.selection.isEmpty { return "\(shown) items" }
        return "\(model.selection.count) of \(shown) selected"
    }

    private var deleteConfirmationTitle: String {
        let count = model.selection.count
        return count == 1 ? "Delete 1 item?" : "Delete \(count) items?"
    }

    private var deleteButtonTitle: String {
        model.kind == .local ? "Move to Trash" : "Delete"
    }
}
