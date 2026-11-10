import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import Nc2ShellCore

@MainActor
final class RemoteFilesModel: ObservableObject {
    let browser = RemoteBrowserState()
    let navigation = RemoteNavigationState()
    let search = RemoteSearchModel()
    let cleanup = TransferCleanupController()
    @Published private(set) var transferItems: [TransferQueueItem] = []
    private var queuedTransfers: [UUID] = []
    private var transferWork: [UUID: TransferWork] = [:]
    private var executions: [UUID: TransferExecution] = [:]
    private let reservations = TransferPathReservations.shared
    private var reservationObserver: AnyCancellable?
    private var interruptedTransfers: Set<UUID> = []
    private var transferSettings: TransferSettingsController?
    private var settingsObserver: AnyCancellable?
    private var maxConcurrentTransfers = 1
    private var listingClient: SFTPClient?
    private var listingOperation = UUID()
    @Published private(set) var path = ""
    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var isTransferring = false
    @Published private(set) var isManagingFiles = false
    @Published private(set) var isPreparingUpload = false
    @Published private(set) var locationValidated = false
    @Published private(set) var transferredBytes: UInt64 = 0
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var following = false {
        didSet { if following != oldValue { onFollowingChanged?() } }
    }
    @Published private(set) var followSuspension: String?
    var onFollowingChanged: (() -> Void)?
    @Published private(set) var reportedPath: String?
    private(set) var connectionID = UUID()
    private(set) var locationRevision = UUID()
    private var makeClient: (() throws -> SFTPClient)?
    private var active: SFTPClient?
    private var operation = UUID()
    private var pendingPath: String?
    private var pendingFollowsTerminal = false
    private var loadingPath: String?
    private var validatedRequestedPath: String?
    private var loadingFollowsTerminal = false
    private var interruptedOperation: UUID?
    private var cancelRequested = false
    private var dropOperation = UUID()
    private var activeConflictPrompt: TransferConflictPrompt?
    private var skippedItems = 0

    func configureTransferSettings(_ settings: TransferSettingsController) {
        guard !isConnected, !isTransferring, queuedTransfers.isEmpty else { return }
        transferSettings = settings
        settingsObserver = settings.$preferences.sink { [weak self] preferences in
            self?.maxConcurrentTransfers = preferences.maxConcurrentTransfers
            DispatchQueue.main.async { [weak self] in self?.startNextTransfer() }
        }
    }
    private(set) var server = ""
    private let conflictPresenter: TransferConflictPrompt.Presenter?
    private var recoveryManager: TransferRecoveryManager?
    private var recoveryProfile: ConnectionProfile?

    init(conflictPresenter: TransferConflictPrompt.Presenter? = nil) {
        self.conflictPresenter = conflictPresenter
        reservationObserver = reservations.changes.sink { [weak self] in
            self?.objectWillChange.send()
            self?.startNextTransfer()
        }
    }

    func configureRecovery(_ manager: TransferRecoveryManager, profile: ConnectionProfile) {
        guard !isConnected, !isTransferring, queuedTransfers.isEmpty else { return }
        recoveryManager = manager; recoveryProfile = profile
    }

    private func recoveryRecord(name: String, direction: RecoverableTransfer.Direction,
                                roots: [RecoverableTransfer.Root], finder: Bool = false) -> RecoverableTransfer? {
        guard recoveryManager != nil, let recoveryProfile else { return nil }
        return RecoverableTransfer(account: TransferRecoveryAccount(profile: recoveryProfile), name: name,
                                   direction: direction, roots: roots, requiresDestinationConfirmation: finder,
                                   attributes: transferSettings?.preferences.attributes ?? .init())
    }

    func preparePromiseRecovery(_ file: RemoteFile, target: URL, batch: RemoteDownloadBatch) throws -> TransferRecoveryTicket? {
        guard let recoveryManager else { return nil }
        guard isConnected, connectionID == batch.connectionID,
              batch.hasStarted || (validateSelection(batch.directory, batch.connectionID) && canDownload([file])) else {
            throw ProfileError("连接或目录已变化，请重新拖出项目。")
        }
        guard let record = recoveryRecord(name: file.name, direction: .download,
                                          roots: [.init(localPath: target.path, remotePath: RemoteFile.join(batch.directory, file.name), allowRootRename: batch.allowRootRename)],
                                          finder: !batch.allowRootRename) else { return nil }
        // Finder 已给出的每个落点先保存，不能等上一项结束才记下尚未排入模型的请求。
        return try recoveryManager.register(record)
    }

    func recoverTransfer(_ id: UUID, confirmedDestination: URL? = nil) {
        error = nil
        guard let recoveryManager, let profile = recoveryProfile, isConnected, !isManagingFiles else {
            error = "请先连接原服务器，并等待文件操作结束后续传。"; return
        }
        do {
            let record = try recoveryManager.store.load().first { $0.id == id }
            guard let record, record.account.matches(profile) else { throw ProfileError("恢复记录与当前服务器或账户不匹配。") }
            if record.requiresDestinationConfirmation {
                guard record.roots.count == 1, let confirmedDestination,
                      confirmedDestination.standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: record.roots[0].localPath).standardizedFileURL.resolvingSymlinksInPath() else {
                    throw ProfileError("Finder 断点与原下载位置绑定，请重新确认原目标后续传；更换目标请重新下载。")
                }
            }
            let ticket = try recoveryManager.acquire(id, profile: profile)
            enqueueRecoverable(record, ticket: ticket)
        } catch { self.error = error.localizedDescription }
    }

    private func enqueueRecoverable(_ record: RecoverableTransfer, ticket provided: TransferRecoveryTicket? = nil,
                                    batch: RemoteDownloadBatch? = nil, completion: @escaping (Error?) -> Void = { _ in }) {
        error = nil
        guard let manager = recoveryManager else { completion(ProfileError("恢复存储不可用。")); return }
        let ticket: TransferRecoveryTicket
        do {
            ticket = try provided ?? manager.register(record)
            guard manager.owns(ticket) else { throw ProfileError("恢复任务的执行占用已失效。") }
        } catch { self.error = error.localizedDescription; completion(error); return }
        let connection = connectionID
        let token = ticket.token
        enqueueTransfer(record.direction == .upload ? "正在上传…" : "正在下载…", name: record.name,
                        direction: record.direction == .upload ? .upload : .download,
                        source: record.roots.map { record.direction == .upload ? $0.localPath : $0.remotePath }.joined(separator: "\n"),
                        target: record.roots.map { record.direction == .upload ? $0.remotePath : $0.localPath }.joined(separator: "\n"),
                        roots: record.roots, batch: batch, itemCount: record.roots.count, recoveryTicket: ticket,
                        estimate: { client in
                            if record.direction == .upload { return try await client.estimateUploadBytes(record.roots.map { URL(fileURLWithPath: $0.localPath) }) }
                            return try await client.estimateDownloadBytes(record.roots.map(\.remotePath))
                        }, completion: completion) { [weak self] client, resolve, progress in
            let checkpoint = try TransferCheckpoint(fileURL: manager.store.checkpointURL(for: record.id), attributes: record.attributes, onReusedBytes: { [weak self] bytes in
                Task { @MainActor in
                    guard let self, self.connectionID == connection,
                          let runningID = self.executions.first(where: { $0.value.work.recoveryTicket?.token == token })?.key else { return }
                    self.transferItems.first { $0.id == runningID }?.recordReused(bytes)
                }
            })
            var completed: UInt64 = 0
            var skipped = 0
            for (index, root) in record.roots.enumerated() {
                if self?.connectionID == connection, self?.executions.count == 1 { self?.message = "正在处理 \(index + 1)/\(record.roots.count)：\(record.name)…" }
                let baseline = completed
                let result: TransferResult
                if record.direction == .upload {
                    result = try await client.upload(local: URL(fileURLWithPath: root.localPath), remote: root.remotePath,
                                                     resolveConflict: { try await resolve($0) }, checkpoint: checkpoint) { progress(baseline + $0) }
                } else {
                    result = try await client.download(remote: root.remotePath, local: URL(fileURLWithPath: root.localPath),
                                                       resolveConflict: { try await resolve($0) }, allowRootRename: root.allowRootRename,
                                                       checkpoint: checkpoint) { progress(baseline + $0) }
                }
                completed += result.bytes
                if let batch { batch.skippedCount += result.skippedCount }
                skipped += result.skippedCount
            }
            return TransferResult(bytes: completed, skippedCount: skipped)
        }
    }

    func makeConflictPrompt() -> TransferConflictPrompt {
        if let conflictPresenter { return TransferConflictPrompt(server: server, present: conflictPresenter) }
        return TransferConflictPrompt(server: server)
    }

    var canEnqueue: Bool { isConnected && locationValidated && !isLoading && !isManagingFiles && !isPreparingUpload }
    var canTransfer: Bool { canEnqueue && !isTransferring && queuedTransfers.isEmpty }
    var canManageFiles: Bool { canTransfer && reservations.isIdle }
    var activeTransferCount: Int { executions.count }
    var soleActiveTransferID: UUID? { executions.count == 1 ? executions.keys.first : nil }

    func prepareCleanup(_ id: UUID, manager: TransferRecoveryManager) {
        guard canTransfer else { error = "请等待当前传输或文件操作结束后再检查清理。"; return }
        error = nil
        cleanup.prepare(id, manager: manager)
    }

    func connect(profile: ConnectionProfile, controlPath: String, initialDirectory: String? = nil) {
        disconnect()
        interruptedOperation = nil; interruptedTransfers.removeAll(); error = nil; message = nil
        server = profile.destination
        if recoveryManager != nil { recoveryProfile = profile }
        let limiter = transferSettings?.limiter
        makeClient = { try SFTPClient(profile: profile, controlPath: controlPath, bandwidthLimiter: limiter) }
        if let makeClient { search.connect(connectionID: connectionID, makeClient: makeClient) }
        if let makeClient { cleanup.connect(profile: profile, makeClient: makeClient) }
        isConnected = true
        following = true
        reportedPath = initialDirectory
        navigate(initialDirectory ?? ".")
    }

    func disconnect() {
        cleanup.disconnect()
        search.disconnect()
        isConnected = false
        activeConflictPrompt?.cancel(); activeConflictPrompt = nil
        let disconnected = SFTPError.message("连接已断开，队列已停止；重新连接后请重新添加任务。")
        let waiting = queuedTransfers; queuedTransfers.removeAll()
        for id in waiting { finishQueuedTransfer(id, error: disconnected) }
        // 主动断开和进程退出可能连续清理，保留尚未返回错误的传输标识。
        interruptedTransfers.formUnion(executions.keys)
        let retiring = executions; executions.removeAll()
        for execution in retiring.values {
            execution.conflicts.cancel()
            execution.work.batch?.stop(disconnected)
            execution.client?.cancel()
        }
        listingOperation = UUID(); listingClient?.cancel(); listingClient = nil
        if isTransferring {
            interruptedOperation = operation
            error = isManagingFiles ? "文件操作已中断，部分更改可能已生效。" : "传输已中断，正在确认未完成文件的位置…"
        }
        connectionID = UUID()
        locationRevision = UUID()
        dropOperation = UUID()
        isPreparingUpload = false
        operation = UUID()
        active?.cancel(); active = nil; makeClient = nil
        isConnected = false; isLoading = false; isTransferring = false
        isManagingFiles = false
        locationValidated = false; following = false; reportedPath = nil; followSuspension = nil
        files = []; path = ""; pendingPath = nil; pendingFollowsTerminal = false; loadingPath = nil; message = nil
        validatedRequestedPath = nil
        navigation.reset()
    }

    func follow(_ path: String) {
        guard followSuspension == nil else { return }
        reportedPath = path
        if following, isManagingFiles { pendingPath = path; pendingFollowsTerminal = true; return }
        // Shell 可能报告符号链接路径；本次成功列表已确认它与当前规范路径对应。
        if following, loadingPath != path, (self.path != path && validatedRequestedPath != path) || !locationValidated {
            navigate(path, followed: true)
        }
    }

    func suspendFollowing(reason: String) {
        followSuspension = reason
        if pendingFollowsTerminal { pendingPath = nil; pendingFollowsTerminal = false }
        if isLoading, loadingFollowsTerminal { navigate(path.isEmpty ? "." : path) }
    }

    func resumeFollowing(path: String?) {
        followSuspension = nil
        if let path { follow(path) }
    }

    func setFollowing(_ enabled: Bool) {
        guard following != enabled else { return }
        following = enabled
        if !enabled {
            pendingPath = nil; pendingFollowsTerminal = false
            if isLoading, loadingFollowsTerminal { navigate(path.isEmpty ? "." : path) }
        }
        if enabled, followSuspension == nil, let reportedPath { navigate(reportedPath, followed: true) }
    }

    func browse(_ path: String) {
        following = false
        navigate(path)
    }

    func prepareSearch() -> Bool {
        guard isConnected, locationValidated, !isLoading, !isManagingFiles else { return false }
        search.prepare(directory: path, includeHidden: browser.showHidden)
        return true
    }

    func openSearchResult(_ result: RemoteSearchMatch) -> Bool {
        guard isConnected, !isManagingFiles, search.isConnected, search.connectionID == connectionID,
              search.snapshot.matches.contains(result) else { return false }
        browser.query = ""
        if result.file.name.hasPrefix(".") { browser.showHidden = true }
        browse((result.path as NSString).deletingLastPathComponent)
        return true
    }

    func refresh() { navigate(path.isEmpty ? "." : path) }

    var canGoBack: Bool { isConnected && !isLoading && !isManagingFiles && navigation.canGoBack }
    var canGoForward: Bool { isConnected && !isLoading && !isManagingFiles && navigation.canGoForward }

    func goBack() {
        guard canGoBack, let target = navigation.backTarget else { return }
        following = false
        navigate(target.path, historyTarget: target)
    }

    func goForward() {
        guard canGoForward, let target = navigation.forwardTarget else { return }
        following = false
        navigate(target.path, historyTarget: target)
    }

    private func navigate(_ requested: String, followed: Bool = false, historyTarget: RemoteNavigationState.Target? = nil) {
        guard isConnected, let makeClient else { return }
        if isManagingFiles { pendingPath = requested; pendingFollowsTerminal = followed; return }
        locationRevision = UUID()
        listingClient?.cancel()
        let id = UUID(); listingOperation = id
        loadingPath = requested; loadingFollowsTerminal = followed
        validatedRequestedPath = nil
        isLoading = true; locationValidated = false; error = nil; files = []
        Task {
            guard listingOperation == id, isConnected else { return }
            do {
                let client = try makeClient(); listingClient = client
                let result = try await client.list(path: requested)
                guard listingOperation == id else { return }
                validatedRequestedPath = requested
                path = result.path; files = result.files; locationValidated = true
                navigation.commit(result.path, target: historyTarget)
            } catch {
                guard listingOperation == id else { return }
                self.error = "无法打开 \(requested)：\(error.localizedDescription)"
            }
            guard listingOperation == id else { return }
            listingClient?.cancel(); listingClient = nil; isLoading = false; loadingPath = nil
            startNextTransfer()
        }
    }

    func upload(_ urls: [URL], expectedPath: String, connectionID: UUID, revision: UUID) {
        guard validateSelection(expectedPath, connectionID, revision: revision), canEnqueue, !urls.isEmpty else { return }
        if let record = recoveryRecord(name: urls.count == 1 ? urls[0].lastPathComponent : "上传 \(urls.count) 项", direction: .upload,
                                       roots: urls.map { .init(localPath: $0.path, remotePath: RemoteFile.join(expectedPath, $0.lastPathComponent)) }) {
            enqueueRecoverable(record)
            return
        }
        enqueueTransfer("正在上传…", name: urls.count == 1 ? urls[0].lastPathComponent : "上传 \(urls.count) 项",
                        direction: .upload, source: urls.map(\.path).joined(separator: "\n"), target: expectedPath,
                        roots: urls.map { .init(localPath: $0.path, remotePath: RemoteFile.join(expectedPath, $0.lastPathComponent)) },
                        estimate: { try await $0.estimateUploadBytes(urls) }) { [weak self] client, resolve, progress in
            var completed: UInt64 = 0
            var skipped = 0
            for (index, url) in urls.enumerated() {
                try RemoteFile.validateName(url.lastPathComponent)
                if self?.connectionID == connectionID, self?.executions.count == 1 { self?.message = "正在上传 \(index + 1)/\(urls.count)：\(url.lastPathComponent)…" }
                let baseline = completed
                let result = try await client.upload(local: url, remote: RemoteFile.join(expectedPath, url.lastPathComponent),
                                                     resolveConflict: { try await resolve($0) }) { bytes in progress(baseline + bytes) }
                completed += result.bytes
                skipped += result.skippedCount
            }
            return TransferResult(bytes: completed, skippedCount: skipped)
        }
    }

    func uploadDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        guard canEnqueue, !providers.isEmpty,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        let directory = path, connection = connectionID, revision = locationRevision, id = UUID()
        dropOperation = id
        isPreparingUpload = true; error = nil; message = "正在读取拖入项目…"
        LocalFileDrop.load(providers) { [weak self] result in
            guard let self, self.dropOperation == id else { return }
            self.isPreparingUpload = false; self.message = nil
            switch result {
            case .success(let urls):
                guard self.locationRevision == revision else {
                    self.error = "目录列表已变化，请重新拖入项目。"; return
                }
                guard self.validateSelection(directory, connection), self.canEnqueue else { return }
                self.upload(urls, expectedPath: directory, connectionID: connection, revision: revision)
            case .failure(let error):
                self.error = "无法读取拖入项目：\(error.localizedDescription)"
            }
        }
        return true
    }

    func promiseProvider(for file: RemoteFile) -> NSFilePromiseProvider? {
        guard canEnqueue, files.contains(file), file.kind == .file || file.kind == .directory else { return nil }
        return RemoteDownloadPromise(file: file, directory: path, connectionID: connectionID, model: self)
    }

    func canDownload(_ selected: [RemoteFile]) -> Bool {
        canEnqueue && !selected.isEmpty && selected.allSatisfy { files.contains($0) && ($0.kind == .file || $0.kind == .directory) }
    }

    func canManage(_ selected: [RemoteFile]) -> Bool {
        canManageFiles && !selected.isEmpty && selected.allSatisfy {
            files.contains($0) && ($0.kind == .file || $0.kind == .directory)
        }
    }

    func createDirectory(_ name: String, expectedPath: String, connectionID: UUID, revision: UUID) {
        guard validateFileOperation(expectedPath, connectionID, revision: revision) else { return }
        transfer("正在新建文件夹…", successMessage: "已新建文件夹：\(name)") { client, _ in
            try await client.createDirectory(in: expectedPath, name: name)
        }
    }

    func rename(_ file: RemoteFile, to name: String, expectedPath: String, connectionID: UUID, revision: UUID) {
        guard validateFileOperation(expectedPath, connectionID, revision: revision, selected: [file]) else { return }
        transfer("正在重命名…", successMessage: "已重命名为：\(name)") { client, _ in
            try await client.rename(file, in: expectedPath, to: name)
        }
    }

    func setPermissions(_ file: RemoteFile, to text: String, expectedPath: String, connectionID: UUID, revision: UUID) {
        guard validateFileOperation(expectedPath, connectionID, revision: revision, selected: [file]) else { return }
        let permissions: UInt32
        do { permissions = try RemotePermissions.parse(text) }
        catch { self.error = error.localizedDescription; return }
        transfer("正在修改权限…", successMessage: "已修改权限：\(file.name)") { client, _ in
            try await client.setPermissions(file, in: expectedPath, permissions: permissions)
        }
    }

    func delete(_ selected: [RemoteFile], expectedPath: String, connectionID: UUID, revision: UUID) {
        guard !selected.isEmpty, validateFileOperation(expectedPath, connectionID, revision: revision, selected: selected) else { return }
        transfer("正在删除 \(selected.count) 项…", successMessage: "已删除 \(selected.count) 项") { client, _ in
            do {
                for file in selected { try await client.delete(file, in: expectedPath) }
            } catch {
                throw SFTPError.message("\(error.localizedDescription)\n已停止剩余删除，部分内容可能已永久删除，无法撤销。")
            }
        }
    }

    private func validateFileOperation(_ expectedPath: String, _ connectionID: UUID, revision: UUID, selected: [RemoteFile] = []) -> Bool {
        guard validateSelection(expectedPath, connectionID, revision: revision) else { return false }
        guard canManageFiles else { error = "当前有传输或文件操作，请完成后重试。"; return false }
        guard selected.isEmpty || canManage(selected) else {
            error = "请选择当前目录中的普通文件或文件夹，项目可能已变化。"; return false
        }
        return true
    }

    func download(_ selected: [RemoteFile], into directory: URL, expectedPath: String, connectionID: UUID, revision: UUID) {
        guard validateSelection(expectedPath, connectionID, revision: revision) else { return }
        guard canEnqueue else { error = "当前正在读取目录或准备其他操作，请完成后重试。"; return }
        guard canDownload(selected) else { error = "请选择当前目录中的普通文件或文件夹，不支持符号链接或特殊文件。"; return }
        if let record = recoveryRecord(name: "下载 \(selected.count) 项", direction: .download,
                                       roots: selected.map { .init(localPath: directory.appendingPathComponent($0.name).path, remotePath: RemoteFile.join(expectedPath, $0.name)) }) {
            enqueueRecoverable(record)
            return
        }
        enqueueTransfer("正在下载…", name: "下载 \(selected.count) 项", direction: .download,
                        source: selected.map { RemoteFile.join(expectedPath, $0.name) }.joined(separator: "\n"), target: directory.path,
                        roots: selected.map { .init(localPath: directory.appendingPathComponent($0.name).path, remotePath: RemoteFile.join(expectedPath, $0.name)) }, itemCount: selected.count,
                        successMessage: "已下载 \(selected.count)/\(selected.count) 项",
                        estimate: { try await $0.estimateDownloadBytes(selected.map { RemoteFile.join(expectedPath, $0.name) }) }) { [weak self] client, resolve, progress in
            var completed: UInt64 = 0
            var skipped = 0
            for (index, file) in selected.enumerated() {
                if self?.connectionID == connectionID, self?.executions.count == 1 { self?.message = "正在下载 \(index + 1)/\(selected.count)：\(file.name)…" }
                let baseline = completed
                let result = try await client.download(remote: RemoteFile.join(expectedPath, file.name), local: directory.appendingPathComponent(file.name),
                                                       resolveConflict: { try await resolve($0) }) { progress(baseline + $0) }
                completed += result.bytes
                skipped += result.skippedCount
            }
            return TransferResult(bytes: completed, skippedCount: skipped)
        }
    }

    func download(_ file: RemoteFile, to url: URL, expectedPath: String, connectionID: UUID, revision: UUID, completion: @escaping (Error?) -> Void = { _ in }) {
        guard validateSelection(expectedPath, connectionID, revision: revision) else {
            completion(SFTPError.message(error ?? "目录或连接已变化。")); return
        }
        guard canDownload([file]) else {
            let reason = "当前正在读取目录或准备其他操作，或所选文件已变化。"
            error = reason; completion(SFTPError.message(reason)); return
        }
        let remote = RemoteFile.join(expectedPath, file.name)
        if let record = recoveryRecord(name: file.name, direction: .download, roots: [.init(localPath: url.path, remotePath: remote)]) {
            enqueueRecoverable(record, completion: completion)
            return
        }
        enqueueTransfer("正在下载 \(file.name)…", name: file.name, direction: .download, source: remote, target: url.path,
                        roots: [.init(localPath: url.path, remotePath: remote)], estimate: { try await $0.estimateDownloadBytes([remote]) }, completion: completion) { client, resolve, progress in
            try await client.download(remote: remote, local: url, resolveConflict: { try await resolve($0) }, progress: progress)
        }
    }

    func downloadPromise(_ file: RemoteFile, to url: URL, batch: RemoteDownloadBatch, recoveryTicket: TransferRecoveryTicket? = nil, completion: @escaping (Error?) -> Void) {
        guard isConnected, connectionID == batch.connectionID else {
            completion(SFTPError.message("连接已变化，请重新拖出文件。")); return
        }
        if !batch.hasStarted {
            guard validateSelection(batch.directory, batch.connectionID) else {
                completion(SFTPError.message(error ?? "目录已变化，请重新拖出文件。")); return
            }
            guard canDownload([file]) else {
                completion(SFTPError.message("当前正在读取目录或操作文件，或所选项目已变化，请完成后重试。")); return
            }
            batch.hasStarted = true
        }
        let remote = RemoteFile.join(batch.directory, file.name)
        if let recoveryTicket {
            enqueueRecoverable(recoveryTicket.record, ticket: recoveryTicket, batch: batch, completion: completion)
            return
        }
        enqueueTransfer("正在下载 \(batch.completed + 1)/\(batch.count)：\(file.name)…", name: file.name, direction: .download,
                        source: remote, target: url.path, roots: [.init(localPath: url.path, remotePath: remote)], batch: batch,
                        estimate: { try await $0.estimateDownloadBytes([remote]) }, completion: completion) { client, resolve, progress in
            let result = try await client.download(remote: remote, local: url, resolveConflict: { try await resolve($0) },
                                                   allowRootRename: batch.allowRootRename, progress: progress)
            batch.skippedCount += result.skippedCount
            return result
        }
    }

    private func transfer(_ label: String, itemCount: Int? = nil, successMessage: String? = nil,
                          conflicts: TransferConflictPrompt? = nil,
                          action: @escaping @MainActor (SFTPClient, @escaping SFTPClient.Progress) async throws -> Void) {
        let id = UUID()
        guard canManageFiles, let makeClient, reservations.acquireExclusive(id: id) else {
            error = "当前有传输或文件操作，请完成后重试。"; return
        }
        operation = id
        activeConflictPrompt = conflicts
        skippedItems = 0
        isTransferring = true; transferredBytes = 0; error = nil; message = label
        isManagingFiles = true; cancelRequested = false
        Task {
            // 断线也要等异步写入实际结束，才能让其他会话开始操作同一路径。
            defer { reservations.release(id: id) }
            guard operation == id, isConnected else { return }
            do {
                let client = try makeClient(); active = client
                if cancelRequested { client.cancel() }
                try await action(client) { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.operation == id else { return }
                        self.transferredBytes = bytes
                    }
                }
                guard operation == id else { return }
                message = skippedItems > 0
                    ? "\(itemCount.map { "已处理 \($0)/\($0) 项" } ?? "操作完成")，跳过 \(skippedItems) 个同名项目"
                    : successMessage ?? "操作完成"
            } catch {
                let detail = "\(error.localizedDescription)\n操作可能已生效，请刷新目录确认结果。"
                guard operation == id else {
                    if !isConnected, interruptedOperation == id { self.error = "文件操作已中断：\(detail)" }
                    return
                }
                self.error = detail; message = nil
            }
            active?.cancel(); active = nil; activeConflictPrompt = nil
            isManagingFiles = false; isTransferring = false
            let transferError = error
            let next = pendingPath ?? path, followed = pendingPath != nil && pendingFollowsTerminal
            pendingPath = nil; pendingFollowsTerminal = false
            navigate(next, followed: followed)
            if let transferError { error = transferError }
        }
    }

    private func enqueueTransfer(_ label: String, name: String, direction: TransferQueueItem.Direction, source: String, target: String,
                                 roots: [RecoverableTransfer.Root] = [], scopes suppliedScopes: [TransferPathReservations.Scope]? = nil,
                                 batch: RemoteDownloadBatch? = nil, itemCount: Int? = nil, successMessage: String? = nil,
                                 recoveryTicket: TransferRecoveryTicket? = nil,
                                 estimate: @escaping TransferWork.Estimate,
                                 completion: @escaping (Error?) -> Void = { _ in }, action: @escaping TransferWork.Action) {
        let scopes: [TransferPathReservations.Scope]
        do { scopes = try suppliedScopes ?? TransferPathReservations.Scope.capture(roots: roots, upload: direction == .upload) }
        catch {
            self.error = error.localizedDescription
            if let recoveryTicket { recoveryManager?.finish(recoveryTicket, completed: false) }
            completion(error); return
        }
        let item = TransferQueueItem(connectionID: connectionID, name: name, direction: direction, source: source,
                                     target: target, isFilePromise: batch != nil)
        item.recoveryID = recoveryTicket?.record.id
        transferItems.append(item)
        transferWork[item.id] = TransferWork(label: label, itemCount: itemCount, successMessage: successMessage, batch: batch,
                                            scopes: scopes, estimate: estimate, recoveryTicket: recoveryTicket,
                                            recoveryManager: recoveryManager, completion: completion, action: action)
        queuedTransfers.append(item.id)
        startNextTransfer()
    }

    private func startNextTransfer() {
        guard isConnected, !isManagingFiles, let makeClient else { return }
        while executions.count < maxConcurrentTransfers,
              let id = queuedTransfers.first,
              let item = transferItems.first(where: { $0.id == id }), let work = transferWork[id] {
            guard item.state != .paused else { return }
            guard item.connectionID == connectionID else {
                queuedTransfers.removeFirst()
                finishQueuedTransfer(id, error: SFTPError.message("连接已变化，请重新添加任务。")); continue
            }
            do { for scope in work.scopes { try scope.revalidate() } }
            catch {
                queuedTransfers.removeFirst(); finishQueuedTransfer(id, error: error); continue
            }
            guard reservations.acquire(id: id, scopes: work.scopes) else { return }
            queuedTransfers.removeFirst()
            let execution = TransferExecution(work: work, conflicts: work.batch?.conflicts ?? makeConflictPrompt())
            executions[id] = execution
            item.state = .running; item.isEstimating = true; item.resetSpeed()
            error = nil
            updateTransferSummary(label: "正在统计传输大小…")
            Task {
                var failure: Error?
                var detail: String?
                do {
                    guard executions[id] === execution, isConnected else { throw SFTPError.message("连接已断开，传输未完成。") }
                    let client = try makeClient(); execution.client = client
                    if work.cancelRequested { client.cancel() }
                    if item.state == .paused { client.setPaused(true) }
                    let total = try await work.estimate(client)
                    guard executions[id] === execution, connectionID == item.connectionID else { throw SFTPError.message("连接已变化，传输未完成。") }
                    for scope in work.scopes { try scope.revalidate() }
                    item.finishEstimation(total)
                    updateTransferSummary(label: work.label)
                    let result = try await work.action(client, { conflict in
                        item.isWaitingForConflict = true; item.resetSpeed()
                        defer { item.isWaitingForConflict = false; item.resetSpeed() }
                        return try await execution.conflicts.resolve(conflict)
                    }, { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, self.executions[id] === execution, self.connectionID == item.connectionID else { return }
                            item.record(bytes)
                            self.updateTransferSummary()
                        }
                    })
                    guard executions[id] === execution, connectionID == item.connectionID else {
                        throw SFTPError.message("连接已变化，请确认传输结果后重试。")
                    }
                    item.record(result.bytes)
                    let skipped = work.batch?.skippedCount ?? result.skippedCount
                    if skipped > 0 {
                        detail = work.batch.map { "已处理 \($0.completed + 1)/\($0.count) 项，跳过 \(skipped) 个同名项目" }
                            ?? "\(work.itemCount.map { "已处理 \($0)/\($0) 项" } ?? "传输完成")，跳过 \(skipped) 个同名项目"
                    } else { detail = work.successMessage ?? work.batch.map { "已下载 \($0.completed + 1)/\($0.count) 项" } ?? "传输完成" }
                } catch { failure = error; detail = error.localizedDescription }
                execution.client?.cancel(); execution.client = nil
                if execution.conflicts.wasCancelledByUser { work.cancelRequested = true }
                let isCurrent = executions[id] === execution && connectionID == item.connectionID
                if isCurrent {
                    executions[id] = nil
                    if let failure { error = failure.localizedDescription }
                    message = failure == nil ? detail : nil
                    updateTransferSummary(label: executions.values.first?.work.label)
                } else if !isConnected, interruptedTransfers.contains(id), let failure {
                    error = "传输已中断：\(failure.localizedDescription)"
                }
                interruptedTransfers.remove(id)
                // 先清理活动槽位和路径占用；Finder 完成回调可能同步排入下一项。
                reservations.release(id: id)
                finishQueuedTransfer(id, error: failure, detail: detail)
                guard isCurrent else { return }
                startNextTransfer()
                if executions.isEmpty, queuedTransfers.isEmpty, isConnected, !isLoading {
                    let transferError = error
                    refresh()
                    if let transferError { error = transferError }
                }
            }
        }
    }

    private func updateTransferSummary(label: String? = nil) {
        isTransferring = isManagingFiles || !executions.isEmpty
        if !executions.isEmpty {
            transferredBytes = transferItems.filter { executions[$0.id] != nil }.reduce(0) { $0 + $1.bytes }
        }
        if executions.count > 1 { message = "正在处理 \(executions.count) 个传输任务" }
        else if let label { message = label }
    }

    private func finishQueuedTransfer(_ id: UUID, error: Error?, detail: String? = nil) {
        guard let item = transferItems.first(where: { $0.id == id }), let work = transferWork[id], !item.state.isFinished else { return }
        item.state = error == nil ? .completed : work.cancelRequested ? .cancelled : .failed
        item.detail = error?.localizedDescription ?? detail
        item.isEstimating = false; item.isWaitingForConflict = false; item.resetSpeed()
        work.finish(error)
        if item.isFilePromise || item.state != .failed { transferWork[id] = nil }
    }

    func pauseTransfer(_ id: UUID) {
        guard executions[id] != nil || queuedTransfers.contains(id) else { return }
        guard let item = transferItems.first(where: { $0.id == id }), item.state == .running || item.state == .queued else { return }
        item.state = .paused; item.resetSpeed()
        executions[id]?.client?.setPaused(true)
    }

    func resumeTransfer(_ id: UUID) {
        guard executions[id] != nil || queuedTransfers.contains(id) else { return }
        guard let item = transferItems.first(where: { $0.id == id }), item.state == .paused else { return }
        item.state = executions[id] != nil ? .running : .queued; item.resetSpeed()
        if let execution = executions[id] { execution.client?.setPaused(false) }
        else { startNextTransfer() }
    }

    func cancelQueuedTransfer(_ id: UUID) {
        // 断线后的旧行仍可能可见，必须等原 Task 收尾才能交还恢复占用和 Finder 回调。
        guard executions[id] != nil || queuedTransfers.contains(id) else { return }
        guard let item = transferItems.first(where: { $0.id == id }), !item.state.isFinished else { return }
        transferWork[id]?.cancelRequested = true
        if let execution = executions[id] {
            execution.conflicts.cancel()
            execution.work.batch?.stop(SFTPError.message("已取消本批下载，已完成的文件保留。"))
            execution.client?.cancel()
            return
        }
        queuedTransfers.removeAll { $0 == id }
        finishQueuedTransfer(id, error: SFTPError.message("已取消等待中的任务。"))
        startNextTransfer()
    }

    func canRetry(_ item: TransferQueueItem) -> Bool {
        isConnected && item.connectionID == connectionID && item.recoveryID == nil && !item.isFilePromise && item.state == .failed && transferWork[item.id] != nil && !isManagingFiles
    }

    func retryTransfer(_ id: UUID) {
        guard let item = transferItems.first(where: { $0.id == id }), canRetry(item), let work = transferWork[id] else { return }
        // 新任务从头校验并重新询问冲突；已经完成的部分不被视为不存在。
        enqueueTransfer(work.label, name: item.name, direction: item.direction, source: item.source, target: item.target,
                        scopes: work.scopes, itemCount: work.itemCount, successMessage: work.successMessage, estimate: work.estimate, action: work.action)
    }

    func clearCompletedTransfers() {
        transferItems.removeAll { $0.state == .completed }
    }

    func relocate(_ selected: [RemoteFile], toDirectory: String, copy: Bool, expectedPath: String, connectionID: UUID, revision: UUID) {
        guard !selected.isEmpty, validateFileOperation(expectedPath, connectionID, revision: revision, selected: selected) else { return }
        let conflicts = makeConflictPrompt()
        transfer(copy ? "正在复制…" : "正在移动…", itemCount: selected.count, successMessage: "已\(copy ? "复制" : "移动") \(selected.count) 项",
                 conflicts: conflicts) { [weak self] client, progress in
            var total: UInt64 = 0
            for file in selected {
                let baseline = total
                let result: TransferResult
                if copy {
                    result = try await client.copy(file, from: expectedPath, toDirectory: toDirectory,
                                                   resolveConflict: { try await conflicts.resolve($0) }) { progress(baseline + $0) }
                } else {
                    result = try await client.move(file, from: expectedPath, toDirectory: toDirectory,
                                                   resolveConflict: { try await conflicts.resolve($0) }) { progress(baseline + $0) }
                }
                total += result.bytes; if self?.connectionID == connectionID { self?.skippedItems += result.skippedCount }
            }
        }
    }

    func cancelTransfer() {
        for id in Array(executions.keys) { cancelQueuedTransfer(id) }
        cancelRequested = true
        activeConflictPrompt?.cancel()
        active?.cancel()
    }

    private func validateSelection(_ expectedPath: String, _ connectionID: UUID, revision: UUID? = nil) -> Bool {
        guard isConnected, self.connectionID == connectionID, path == expectedPath, locationValidated else {
            error = "目录或连接已变化，请重新选择要操作的项目。"
            return false
        }
        if let revision, locationRevision != revision {
            error = "目录列表已变化，请重新选择并确认操作。"
            return false
        }
        return true
    }
}
