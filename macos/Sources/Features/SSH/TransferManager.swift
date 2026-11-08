import Foundation
import Combine

/// Runs file transfers one at a time and keeps a short history for the UI.
///
/// Transfers are serialized on purpose: they all share a single multiplexed
/// SSH connection, and running a dozen at once makes every one of them slower
/// while making progress impossible to read.
@MainActor
final class TransferManager: ObservableObject {
    enum Direction {
        case upload
        case download

        var symbolName: String {
            switch self {
            case .upload: return "arrow.up.circle"
            case .download: return "arrow.down.circle"
            }
        }
    }

    enum TransferState: Equatable {
        case queued
        case running
        case completed
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .completed, .failed: return true
            case .queued, .running: return false
            }
        }
    }

    struct Transfer: Identifiable, Equatable {
        let id: UUID
        let name: String
        let direction: Direction
        var state: TransferState
    }

    @Published private(set) var transfers: [Transfer] = []

    private typealias Work = @Sendable () async throws -> Void
    private var pending: [(id: UUID, work: Work)] = []
    private var pump: Task<Void, Never>?

    var activeCount: Int {
        transfers.filter { !$0.state.isFinished }.count
    }

    var hasFinished: Bool {
        transfers.contains { $0.state.isFinished }
    }

    /// Queue a transfer. `completion` runs on the main actor once it finishes,
    /// successfully or not, so callers can refresh their listing.
    func enqueue(
        name: String,
        direction: Direction,
        work: @escaping @Sendable () async throws -> Void,
        completion: @escaping @MainActor (Error?) -> Void = { _ in }
    ) {
        let id = UUID()
        transfers.append(Transfer(id: id, name: name, direction: direction, state: .queued))
        pending.append((id, {
            do {
                try await work()
                await MainActor.run { completion(nil) }
            } catch {
                await MainActor.run { completion(error) }
                throw error
            }
        }))
        startPumpIfNeeded()
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
    }

    // MARK: - Private

    private func startPumpIfNeeded() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while true {
                guard let self else { return }
                guard let next = self.takeNext() else {
                    self.pump = nil
                    return
                }

                self.setState(.running, for: next.id)
                do {
                    try await next.work()
                    self.setState(.completed, for: next.id)
                } catch {
                    self.setState(.failed(error.localizedDescription), for: next.id)
                }
            }
        }
    }

    private func takeNext() -> (id: UUID, work: Work)? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    private func setState(_ state: TransferState, for id: UUID) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].state = state
    }
}
