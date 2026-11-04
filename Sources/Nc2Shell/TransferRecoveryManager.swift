import Foundation
import Combine
import Nc2ShellCore

struct TransferRecoveryTicket {
    let record: RecoverableTransfer
    let token: UUID
    let manager: TransferRecoveryManager
}

@MainActor
final class TransferRecoveryManager: ObservableObject {
    static let shared = TransferRecoveryManager(store: .standard)
    @Published private(set) var records: [RecoverableTransfer] = []
    @Published private(set) var activeIDs: Set<UUID> = []
    @Published private(set) var error: String?
    let store: TransferRecoveryStore
    private var leases: [UUID: UUID] = [:]

    init(store: TransferRecoveryStore) {
        self.store = store
        refresh()
    }

    var pendingRecords: [RecoverableTransfer] { records.filter { !activeIDs.contains($0.id) } }

    func refresh() {
        do { records = try store.load(); error = nil }
        catch { self.error = "读取恢复记录失败：\(error.localizedDescription)" }
    }

    func register(_ record: RecoverableTransfer) throws -> TransferRecoveryTicket {
        guard leases[record.id] == nil else { throw ProfileError("此任务已在传输或排队中。") }
        try store.save(record)
        records = try store.load(); error = nil
        return claim(record)
    }

    func acquire(_ id: UUID, profile: ConnectionProfile, allowingCleanup: Bool = false) throws -> TransferRecoveryTicket {
        guard leases[id] == nil else { throw ProfileError("此任务已在其他会话传输或排队中。") }
        let saved = try store.load()
        guard let record = saved.first(where: { $0.id == id }), record.account.matches(profile) else {
            throw ProfileError("恢复记录与当前服务器或账户不匹配，请连接原服务器。")
        }
        guard allowingCleanup || record.cleanupStartedAt == nil else { throw ProfileError("此任务已放弃续传，请继续检查并清理。") }
        records = saved; error = nil
        return claim(record)
    }

    func markCleanupStarted(_ ticket: TransferRecoveryTicket) throws {
        guard owns(ticket) else { throw ProfileError("任务占用已失效，请重新检查。") }
        try store.markCleanupStarted(ticket.record.id)
        records = try store.load()
    }

    func completeCleanup(_ ticket: TransferRecoveryTicket) throws {
        guard owns(ticket) else { throw ProfileError("任务占用已失效。") }
        try store.removeCompletedCleanup(ticket.record.id)
        records = try store.load()
    }

    private func claim(_ record: RecoverableTransfer) -> TransferRecoveryTicket {
        let token = UUID()
        leases[record.id] = token
        activeIDs.insert(record.id)
        return TransferRecoveryTicket(record: record, token: token, manager: self)
    }

    func owns(_ ticket: TransferRecoveryTicket) -> Bool { leases[ticket.record.id] == ticket.token }

    func finish(_ ticket: TransferRecoveryTicket, completed: Bool) {
        guard owns(ticket) else { return }
        if completed {
            do { try store.remove(ticket.record.id) }
            catch { self.error = "文件已传输，但恢复记录未能清理：\(error.localizedDescription)" }
        }
        leases[ticket.record.id] = nil
        activeIDs.remove(ticket.record.id)
        do { records = try store.load() }
        catch { self.error = "读取恢复记录失败：\(error.localizedDescription)" }
    }

    func removeRecord(_ id: UUID) throws {
        guard leases[id] == nil else { throw ProfileError("请先停止此任务，再移除恢复记录。") }
        try store.remove(id)
        records = try store.load(); error = nil
    }
}
