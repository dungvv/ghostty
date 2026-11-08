import SwiftUI

/// The dual pane local/remote file browser for one SSH connection.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel
    @ObservedObject var transfers: TransferManager

    init(model: FileBrowserModel) {
        self.model = model
        self.transfers = model.transfers
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            panes
            if !transfers.transfers.isEmpty {
                Divider()
                transferBar
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .task { await model.start() }
    }

    // MARK: - Connection bar

    private var connectionBar: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 0) {
                Text(model.connection.displayName)
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }

            Spacer()

            if model.session.state.errorMessage != nil {
                Button {
                    SSHTerminalLauncher.authenticate(session: model.session)
                } label: {
                    Label("Authenticate in Terminal", systemImage: "key")
                }
                .help("Log in interactively. The file browser reuses that connection.")

                Button {
                    Task { await model.checkForDonatedConnection() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            Button {
                SSHTerminalLauncher.connect(
                    model.connection,
                    remoteDirectory: model.remote.path.isEmpty ? nil : model.remote.path)
            } label: {
                Label("Open Terminal", systemImage: "terminal")
            }

            if model.session.state.isConnected {
                Button {
                    model.session.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } else if !model.session.state.isBusy {
                Button {
                    Task { await model.reconnect() }
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusDot: some View {
        Group {
            if model.session.state.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 16)
    }

    private var statusColor: Color {
        switch model.session.state {
        case .connected: return .green
        case .failed: return .red
        case .connecting: return .orange
        case .disconnected: return .secondary
        }
    }

    private var statusText: String {
        switch model.session.state {
        case .connected: return "Connected to \(model.connection.destination)"
        case .connecting: return "Connecting to \(model.connection.destination)…"
        case .disconnected: return "Not connected"
        case .failed(let message): return message
        }
    }

    // MARK: - Panes

    private var panes: some View {
        HSplitView {
            FilePaneView(
                model: model.local,
                subtitle: "This Mac",
                transferTitle: "Upload",
                transferSymbol: "arrow.right",
                onTransfer: { model.upload($0) },
                onOpenTerminal: { path in
                    SSHTerminalLauncher.openTerminal(workingDirectory: path)
                })

            FilePaneView(
                model: model.remote,
                subtitle: model.connection.destination,
                transferTitle: "Download",
                transferSymbol: "arrow.left",
                onTransfer: { model.download($0) },
                onOpenTerminal: { path in
                    SSHTerminalLauncher.connect(model.connection, remoteDirectory: path)
                })
        }
    }

    // MARK: - Transfers

    private var transferBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transfers")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if transfers.hasFinished {
                    Button("Clear Finished") { transfers.clearFinished() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(transfers.transfers) { transfer in
                        transferRow(transfer)
                    }
                }
            }
            .frame(maxHeight: 110)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func transferRow(_ transfer: TransferManager.Transfer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction.symbolName)
                .foregroundStyle(.secondary)
            Text(transfer.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            switch transfer.state {
            case .queued:
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}
