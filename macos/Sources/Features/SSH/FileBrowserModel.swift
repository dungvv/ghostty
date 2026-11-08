import Foundation
import Combine

/// Owns everything behind one file browser window: the SSH session, the two
/// panes and the transfer queue.
@MainActor
final class FileBrowserModel: ObservableObject {
    let connection: SSHConnection
    let session: SSHSession
    let local: FilePaneModel
    let remote: FilePaneModel
    let transfers = TransferManager()

    /// Set when the user should be offered an interactive login.
    @Published var needsInteractiveAuthentication: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    init(connection: SSHConnection) {
        self.connection = connection
        let session = SSHSession(connection: connection)
        self.session = session
        self.local = FilePaneModel(
            kind: .local,
            provider: LocalFileProvider(),
            initialPath: connection.localPath)
        self.remote = FilePaneModel(
            kind: .remote,
            provider: RemoteFileProvider(client: session.client),
            initialPath: connection.remotePath)
        self.remote.isAvailable = false

        // Republish the session's changes so views observing just this model
        // still redraw when the connection state moves.
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        session.$state
            .sink { [weak self] state in
                guard let self else { return }
                self.remote.isAvailable = state.isConnected
                if case .failed = state { self.needsInteractiveAuthentication = true }
                if state.isConnected {
                    self.needsInteractiveAuthentication = false
                    Task { await self.remote.start() }
                }
            }
            .store(in: &cancellables)
    }

    func start() async {
        await local.start()
        await session.connect()
    }

    func reconnect() async {
        session.disconnect()
        await session.connect()
    }

    /// Re-check whether a master socket appeared, e.g. because the user just
    /// authenticated in a terminal window.
    func checkForDonatedConnection() async {
        guard !session.state.isConnected else { return }
        await session.refreshConnectionState()
        if !session.state.isConnected {
            await session.connect()
        }
    }

    // MARK: - Transfers

    func upload(_ items: [FileItem]) {
        guard session.state.isConnected else { return }
        let destinationDirectory = remote.path
        guard !destinationDirectory.isEmpty else { return }
        let client = session.client

        for item in items {
            let source = item.path
            let destination = RemotePath.join(destinationDirectory, item.name)
            let recursive = item.isDirectory
            transfers.enqueue(
                name: item.name,
                direction: .upload,
                work: {
                    try await client.upload(local: source, to: destination, recursive: recursive)
                },
                completion: { [weak self] error in
                    if let error { self?.remote.errorMessage = error.localizedDescription }
                    Task { await self?.remote.reload() }
                })
        }
    }

    func download(_ items: [FileItem]) {
        guard session.state.isConnected else { return }
        let destinationDirectory = local.path
        guard !destinationDirectory.isEmpty else { return }
        let client = session.client

        for item in items {
            let source = item.path
            let destination = RemotePath.join(destinationDirectory, item.name)
            let recursive = item.isDirectory
            transfers.enqueue(
                name: item.name,
                direction: .download,
                work: {
                    try await client.download(remote: source, to: destination, recursive: recursive)
                },
                completion: { [weak self] error in
                    if let error { self?.local.errorMessage = error.localizedDescription }
                    Task { await self?.local.reload() }
                })
        }
    }

    // MARK: - Teardown

    func shutdown() {
        session.disconnect()
    }
}
