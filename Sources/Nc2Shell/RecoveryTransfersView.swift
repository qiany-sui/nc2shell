import AppKit
import SwiftUI
import Nc2ShellCore

struct RecoveryTransfersView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recovery: TransferRecoveryManager
    @State private var confirmingID: UUID?
    @State private var cleanupSession: TerminalSession?
    @State private var showingMetadataCleanup = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { expanded.toggle() } label: {
                    Label(recovery.pendingRecords.isEmpty ? "恢复与清理" : "待恢复传输 · \(recovery.pendingRecords.count)",
                          systemImage: expanded ? "chevron.down" : "chevron.right")
                }.buttonStyle(.plain).font(.system(size: 13))
                Spacer()
            }
            if let error = recovery.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("查看恢复资料位置") { NSWorkspace.shared.open(recovery.store.directoryURL) }
            }
            if expanded {
            HStack {
                Button("清理本地恢复资料…") { showingMetadataCleanup = true }
                Button("刷新恢复记录") { recovery.refresh() }
            }.font(.system(size: 12)).buttonStyle(.borderless)
            if recovery.pendingRecords.isEmpty, recovery.error == nil {
                Text("暂无待恢复任务").font(.caption).foregroundStyle(.secondary)
            } else if !recovery.pendingRecords.isEmpty {
                Text("续传前会校验来源与已有内容，校验期间进度可能暂时不变。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(recovery.pendingRecords) { record in
                recoveryRow(record)
            }
            }
        }
        .sheet(item: $cleanupSession, onDismiss: { recovery.refresh() }) { session in
            TransferCleanupView(controller: session.files.cleanup)
        }
        .sheet(isPresented: $showingMetadataCleanup) { RecoveryMetadataCleanupView(store: recovery.store) }
        .onAppear { expanded = !recovery.pendingRecords.isEmpty }
        .onChange(of: recovery.pendingRecords.count) { old, new in if new > old { expanded = true } }
    }

    private func recoveryRow(_ record: RecoverableTransfer) -> some View {
        let profile = savedProfile(for: record)
        let session = connectedSession(for: record)
        let connecting = model.sessions.contains { record.account.matches($0.profile) && $0.state == .connecting }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: record.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                Text(record.name).lineLimit(1)
                Text("\(record.roots.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let session {
                    if record.cleanupStartedAt == nil {
                        Button(record.requiresDestinationConfirmation ? "确认目标并续传…" : "续传") { resume(record) }
                            .disabled(confirmingID != nil || recovery.error != nil)
                    }
                    Button(record.cleanupStartedAt == nil ? "检查并清理…" : "继续清理…") {
                        session.files.prepareCleanup(record.id, manager: recovery)
                        if let error = session.files.error { model.errorMessage = error }
                        else { cleanupSession = session }
                    }.disabled(confirmingID != nil || !session.files.canTransfer)
                } else if let profile {
                    Button(connecting ? "正在连接…" : "连接服务器") { model.connect(profile) }
                        .disabled(connecting)
                }
                Button("移除记录…", role: .destructive) { remove(record) }
                    .disabled(confirmingID != nil)
            }
            Text("\(profile?.name ?? "原服务器") · \(serverDescription(record))")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if record.cleanupStartedAt != nil {
                Text("已放弃续传，剩余半成品可重新检查后继续清理。").font(.caption).foregroundStyle(.secondary)
            }
            if session == nil {
                Text(profile == nil ? "找不到匹配的已保存连接；请检查原连接的主机、端口和账户。" : connecting ? "请完成终端认证，连接成功后再点击续传。" : "请先连接原服务器，连接后不会自动开始续传。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let root = record.roots.first {
                Text(pathDescription(root, direction: record.direction))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(pathDescription(root, direction: record.direction)).textSelection(.enabled)
            }
            DisclosureGroup("查看全部路径与恢复资料") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(record.roots.enumerated()), id: \.offset) { _, root in
                        Text(pathDescription(root, direction: record.direction)).textSelection(.enabled)
                    }
                    Text("创建时间：\(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("恢复资料：\(recovery.store.checkpointURL(for: record.id).path)").textSelection(.enabled)
                    Button("在 Finder 中查看恢复资料") {
                        NSWorkspace.shared.open(recovery.store.checkpointURL(for: record.id).deletingLastPathComponent())
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }.font(.caption)
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func savedProfile(for record: RecoverableTransfer) -> ConnectionProfile? {
        model.profiles.first { record.account.matches($0) }
    }

    private func connectedSession(for record: RecoverableTransfer) -> TerminalSession? {
        if let selected = model.selectedSession, selected.state == .connected,
           selected.files.isConnected, record.account.matches(selected.profile) { return selected }
        return model.sessions.first { $0.state == .connected && $0.files.isConnected && record.account.matches($0.profile) }
    }

    private func serverDescription(_ record: RecoverableTransfer) -> String {
        let account = record.account
        return (account.username.isEmpty ? "" : "\(account.username)@") + account.host + ":\(account.port)"
    }

    private func pathDescription(_ root: RecoverableTransfer.Root, direction: RecoverableTransfer.Direction) -> String {
        direction == .upload ? "本地：\(root.localPath) → 远程：\(root.remotePath)" : "远程：\(root.remotePath) → 本地：\(root.localPath)"
    }

    private func resume(_ record: RecoverableTransfer) {
        guard record.requiresDestinationConfirmation else {
            startRecovery(record.id, confirmedDestination: nil)
            return
        }
        guard record.roots.count == 1, let root = record.roots.first else {
            model.errorMessage = "Finder 恢复记录的目标数量无效，请检查恢复资料。"
            return
        }
        let original = URL(fileURLWithPath: root.localPath)
        let panel = NSOpenPanel()
        panel.title = "确认原下载位置"
        panel.message = "原目标：\(root.localPath)\n请选择原目标的父目录。续传仍使用原文件名；若要更换位置，请重新发起下载。"
        panel.prompt = "确认并续传"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = original.deletingLastPathComponent()
        confirmingID = record.id
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            confirmingID = nil
            guard response == .OK, let parent = panel.url else { return }
            // 选择框期间连接或任务可能改变，确认后重新查找，不保留旧会话。
            startRecovery(record.id, confirmedDestination: parent.appendingPathComponent(original.lastPathComponent))
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    private func startRecovery(_ id: UUID, confirmedDestination: URL?) {
        guard let record = recovery.pendingRecords.first(where: { $0.id == id }) else {
            model.errorMessage = "此恢复任务已移除，或已在其他会话中开始。"
            return
        }
        guard let session = connectedSession(for: record) else {
            model.errorMessage = "原服务器连接已不可用，请连接后再续传。"
            return
        }
        session.files.recoverTransfer(id, confirmedDestination: confirmedDestination)
        if let error = session.files.error { model.errorMessage = error }
    }

    private func remove(_ record: RecoverableTransfer) {
        guard AppModel.confirm(title: "移除“\(record.name)”的恢复记录？",
                               detail: "移除后无法再通过此记录使用断点续传。已完成的文件、检查点与本地或远程临时内容都会保留，不会删除文件。",
                               action: "移除记录") else { return }
        do { try recovery.removeRecord(record.id) }
        catch { model.errorMessage = error.localizedDescription }
    }
}
