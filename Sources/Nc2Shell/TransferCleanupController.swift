import Foundation
import Combine
import Nc2ShellCore

@MainActor
final class TransferCleanupController: ObservableObject {
    enum Phase { case idle, inspecting, ready, deleting, cancelling, done, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: TransferCleanupPlan?
    @Published private(set) var record: RecoverableTransfer?
    @Published private(set) var error: String?
    @Published private(set) var isConnected = false
    var isWorking: Bool { phase == .inspecting || phase == .deleting || phase == .cancelling }
    private let reservations: TransferPathReservations
    private var profile: ConnectionProfile?
    private var makeClient: (() throws -> SFTPClient)?
    private var active: Operation?

    private final class Operation {
        let id = UUID()
        let ticket: TransferRecoveryTicket
        let client: SFTPClient
        let checkpoint: TransferCheckpoint
        var cancelled = false
        init(ticket: TransferRecoveryTicket, client: SFTPClient, checkpoint: TransferCheckpoint) {
            self.ticket = ticket; self.client = client; self.checkpoint = checkpoint
        }
    }

    init(reservations: TransferPathReservations? = nil) { self.reservations = reservations ?? .shared }

    func connect(profile: ConnectionProfile, makeClient: @escaping () throws -> SFTPClient) {
        disconnect()
        self.profile = profile; self.makeClient = makeClient; isConnected = true
    }

    func disconnect() {
        isConnected = false; profile = nil; makeClient = nil
        cancel()
    }

    func prepare(_ id: UUID, manager: TransferRecoveryManager) {
        guard active == nil else { return }
        plan = nil; record = nil; error = nil
        do {
            guard isConnected, let profile, let makeClient else { throw ProfileError("请先连接原服务器。") }
            let ticket = try manager.acquire(id, profile: profile, allowingCleanup: true)
            let operation: Operation
            do {
                operation = Operation(ticket: ticket, client: try makeClient(), checkpoint: try TransferCheckpoint(fileURL: manager.store.checkpointURL(for: id)))
                guard reservations.acquireExclusive(id: operation.id) else { operation.client.cancel(); throw ProfileError("当前有传输或文件操作，请完成后重试。") }
            } catch { manager.finish(ticket, completed: false); throw error }
            active = operation; record = ticket.record; phase = .inspecting
            Task {
                do {
                    let result = try await operation.client.inspectCleanup(task: ticket.record, checkpoint: operation.checkpoint)
                    guard !operation.cancelled else { throw CancellationError() }
                    plan = result; phase = .ready
                } catch { fail(operation, error: error) }
            }
        } catch { self.error = error.localizedDescription; phase = .failed }
    }

    func confirm() {
        guard phase == .ready, isConnected, let operation = active, let plan, !operation.cancelled else { return }
        do { try operation.ticket.manager.markCleanupStarted(operation.ticket) }
        catch { fail(operation, error: error); return }
        phase = .deleting
        Task {
            do {
                try await operation.client.executeCleanup(task: operation.ticket.record, checkpoint: operation.checkpoint, expectedPlan: plan)
                guard !operation.cancelled else { throw CancellationError() }
                try operation.ticket.manager.completeCleanup(operation.ticket)
                phase = .done; release(operation)
            } catch { fail(operation, error: error) }
        }
    }

    func cancel() {
        guard let operation = active else { return }
        operation.cancelled = true; operation.client.cancel()
        if isWorking { phase = .cancelling }
        else { phase = .idle; plan = nil; release(operation) }
    }

    private func fail(_ operation: Operation, error: Error) {
        self.error = operation.cancelled ? "清理已停止。已删除的部分不会恢复；剩余内容和恢复记录保留，可重新检查。" : error.localizedDescription
        phase = .failed
        release(operation)
    }

    private func release(_ operation: Operation) {
        operation.client.cancel()
        operation.ticket.manager.finish(operation.ticket, completed: false)
        reservations.release(id: operation.id)
        if active === operation { active = nil }
    }
}
