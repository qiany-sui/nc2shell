import AppKit
import Combine
import SwiftUI
import Nc2ShellCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var workspaces: [TerminalWorkspace] = [] {
        didSet { synchronizeSplitPanels() }
    }
    @Published private(set) var selectedWorkspaceID: UUID? {
        didSet { synchronizeSplitPanels() }
    }
    @Published var sidebarVisible = true
    @Published var filesVisible = true
    @Published private(set) var preferences = TerminalPreferences()
    @Published private(set) var settingsError: String?
    @Published var selectedProfileID: UUID?
    @Published var editor: ConnectionProfile?
    @Published var settingsPresented = false
    @Published var errorMessage: String?
    @Published var connectionQuery = ""
    @Published private(set) var storageError: String?
    var onAllSessionsEnded: (() -> Void)?
    private var closingIDs: Set<UUID> = []
    private var panelsBeforeColumnSplit: (sidebar: Bool, files: Bool)?
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var recoveryObserver: AnyCancellable?
    private let store: ConnectionStore
    private let settingsStore: TerminalSettingsStore
    private let credentials: ConnectionCredentials
    private var temporaryPasswords: [UUID: (profile: ConnectionProfile, password: String)] = [:]
    let recovery: TransferRecoveryManager?
    let transferSettings: TransferSettingsController?
    private let sessionFactory: @MainActor (ConnectionProfile) -> TerminalSession

    init(store: ConnectionStore = .standard, settingsStore: TerminalSettingsStore = .standard,
         credentials: ConnectionCredentials = KeychainCredentials(), recovery: TransferRecoveryManager? = nil,
         transferSettings: TransferSettingsController? = nil,
         sessionFactory: @escaping @MainActor (ConnectionProfile) -> TerminalSession = { TerminalSession(profile: $0) }) {
        self.store = store
        self.settingsStore = settingsStore
        self.credentials = credentials
        self.recovery = recovery
        self.transferSettings = transferSettings
        self.sessionFactory = sessionFactory
        do { profiles = try store.load() }
        catch { storageError = "读取连接配置失败：\(error.localizedDescription)" }
        do { preferences = try settingsStore.load() }
        catch { settingsError = "读取终端设置失败，暂用默认值且不会覆盖原文件：\(error.localizedDescription)\n\(settingsStore.fileURL.path)" }
        recoveryObserver = recovery?.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            // Published 在赋值前通知，必须等占用状态提交后再决定是否允许退出。
            DispatchQueue.main.async { [weak self] in self?.notifyIfAllWorkEnded() }
        }
    }

    var selectedProfile: ConnectionProfile? { profiles.first { $0.id == selectedProfileID } }
    var workspaceProfile: ConnectionProfile? {
        guard let session = selectedSession else { return selectedProfile }
        return profiles.first { $0.id == session.profile.id }
    }

    func workspaceTitle(_ workspace: TerminalWorkspace) -> String {
        guard let name = session(workspace.primarySessionID)?.profile.name else { return "会话" }
        let duplicated = workspaces.contains { $0.id != workspace.id && session($0.primarySessionID)?.profile.name == name }
        return duplicated || workspace.tabNumber > 1 ? "\(name) · \(workspace.tabNumber)" : name
    }
    var filteredProfiles: [ConnectionProfile] {
        let query = connectionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { profile in
            [profile.name, profile.host, profile.username].contains { $0.localizedStandardContains(query) }
        }
    }
    var selectedWorkspace: TerminalWorkspace? { workspaces.first { $0.id == selectedWorkspaceID } }
    var selectedSessionID: UUID? {
        get { selectedWorkspace?.focusedSessionID }
        set { if let newValue { focus(newValue) } }
    }
    var selectedSession: TerminalSession? { session(selectedSessionID) }
    var hasRunningSessions: Bool { sessions.contains { $0.isRunning } }
    var hasActiveWork: Bool { hasRunningSessions || recovery?.activeIDs.isEmpty == false }

    func newConnection() {
        guard !settingsPresented else { return }
        editor = ConnectionProfile(name: "", host: "")
    }

    func showSettings() {
        guard editor == nil else { return }
        settingsPresented = true
    }

    func hasTemporaryPassword(for profile: ConnectionProfile) -> Bool {
        temporaryPasswords[profile.id]?.profile.hasSameCredentialAccount(as: profile) == true
    }

    func save(_ profile: ConnectionProfile, password: String? = nil, clearTemporaryPassword: Bool = false) {
        do {
            let profile = try profile.validated()
            let previous = profiles.first { $0.id == profile.id }
            let replacingPassword = password.map { !$0.isEmpty } ?? false
            if profile.rememberPassword && !replacingPassword {
                guard let previous, previous.rememberPassword, previous.hasSameCredentialAccount(as: profile),
                      try credentials.password(for: profile) != nil else {
                    throw ProfileError("请为此主机和用户名输入要记住的密码。")
                }
            }
            if let password, replacingPassword {
                try KeychainCredentials.validate(password)
                guard !profile.username.isEmpty else { throw ProfileError("填写密码时请明确填写用户名，避免使用错误账户。") }
            }
            var updated = profiles
            if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
            else { updated.append(profile) }
            // 先确认原配置可读，再修改钥匙串；配置写失败时恢复原凭据。
            _ = try store.load()
            let changesPassword = profile.rememberPassword && replacingPassword || previous?.rememberPassword == true && (!profile.rememberPassword || previous?.hasSameCredentialAccount(as: profile) == false)
            if changesPassword {
                let oldPassword = try previous.flatMap { $0.rememberPassword ? try credentials.password(for: $0) : nil }
                do {
                    if profile.rememberPassword, replacingPassword, let password { try credentials.setPassword(password, for: profile) }
                    if let previous, previous.rememberPassword, !profile.rememberPassword || !previous.hasSameCredentialAccount(as: profile) {
                        try credentials.setPassword(nil, for: previous)
                    }
                    try store.save(updated)
                } catch {
                    do {
                        if profile.rememberPassword { try credentials.setPassword(nil, for: profile) }
                        if let previous, let oldPassword { try credentials.setPassword(oldPassword, for: previous) }
                    } catch { throw ProfileError("保存失败，且钥匙串恢复失败；请重新检查连接密码。\(error.localizedDescription)") }
                    throw error
                }
            } else { try store.save(updated) }
            // 配置保存成功才提交内存密码；换账户不能沿用旧凭据，明文永不进入连接 JSON。
            if clearTemporaryPassword {
                temporaryPasswords[profile.id] = nil
                // 显式改用 SSH 默认配置后，旧标签的下次重连也不能复用已移除的临时密码。
                for session in sessions where session.profile.hasSameCredentialAccount(as: profile) {
                    session.temporaryPassword = nil
                }
            } else if profile.rememberPassword {
                temporaryPasswords[profile.id] = nil
                if replacingPassword, let password {
                    // 旧临时密码标签仍按原认证方式重连，不能让其快照遮蔽新保存的密码。
                    for session in sessions where session.profile.hasSameCredentialAccount(as: profile) && session.temporaryPassword != nil {
                        session.temporaryPassword = password
                    }
                }
            } else if replacingPassword, let password {
                temporaryPasswords[profile.id] = (profile, password)
                // 修正密码后，原账户的旧标签下次重连也应使用新值；在途认证仍持有自己的快照。
                for session in sessions where session.profile.hasSameCredentialAccount(as: profile) {
                    session.temporaryPassword = password
                }
            } else if temporaryPasswords[profile.id]?.profile.hasSameCredentialAccount(as: profile) != true {
                temporaryPasswords[profile.id] = nil
            }
            profiles = updated
            selectedProfileID = profile.id
            editor = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ profile: ConnectionProfile) {
        guard Self.confirm(title: "删除“\(profile.name)”？", detail: "删除保存的连接配置及其钥匙串密码，已打开的会话会继续运行。", action: "删除") else { return }
        deleteConfirmed(profile)
    }

    func deleteConfirmed(_ profile: ConnectionProfile) {
        do {
            let updated = profiles.filter { $0.id != profile.id }
            _ = try store.load()
            let password = profile.rememberPassword ? try credentials.password(for: profile) : nil
            if profile.rememberPassword { try credentials.setPassword(nil, for: profile) }
            do { try store.save(updated) }
            catch {
                if let password { try credentials.setPassword(password, for: profile) }
                throw error
            }
            profiles = updated
            temporaryPasswords[profile.id] = nil
            if selectedProfileID == profile.id { selectedProfileID = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func connect(_ profile: ConnectionProfile) -> TerminalSession {
        let session = makeSession(profile)
        let number = (workspaces.filter { self.session($0.primarySessionID)?.profile.name == profile.name }.map(\.tabNumber).max() ?? 0) + 1
        let workspace = TerminalWorkspace(sessionID: session.id, tabNumber: number)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        selectedProfileID = profile.id
        session.start()
        return session
    }

    private func makeSession(_ profile: ConnectionProfile) -> TerminalSession {
        let session = sessionFactory(profile)
        if !profile.rememberPassword, let saved = temporaryPasswords[profile.id], saved.profile.hasSameCredentialAccount(as: profile) {
            session.temporaryPassword = saved.password
        }
        if let recovery { session.files.configureRecovery(recovery, profile: profile) }
        if let transferSettings { session.files.configureTransferSettings(transferSettings) }
        session.applyPreferences(preferences)
        session.onEnded = { [weak self, weak session] in
            guard let self, let session else { return }
            if self.closingIDs.remove(session.id) != nil { self.removeSession(session.id) }
            self.notifyIfAllWorkEnded()
        }
        sessions.append(session)
        sessionObservers[session.id] = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return session
    }

    func session(_ id: UUID?) -> TerminalSession? { sessions.first { $0.id == id } }

    func selectWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        focusTerminal()
    }

    func focus(_ id: UUID, requestResponder: Bool = true) {
        guard let index = workspaces.firstIndex(where: { $0.sessionIDs.contains(id) }) else { return }
        if workspaces[index].focusedSessionID != id { workspaces[index].focusedSessionID = id }
        if selectedWorkspaceID != workspaces[index].id { selectedWorkspaceID = workspaces[index].id }
        if requestResponder { focusTerminal() }
    }

    func focusNextPane() {
        guard let workspace = selectedWorkspace, let other = workspace.sessionIDs.first(where: { $0 != workspace.focusedSessionID }) else { return }
        focus(other)
    }

    private func focusTerminal() {
        guard let terminal = selectedSession?.terminal else { return }
        terminal.window?.makeFirstResponder(terminal)
    }

    @discardableResult
    func split(_ axis: TerminalSplitAxis = .rows) -> TerminalSession? {
        guard let workspace = selectedWorkspace, let selected = selectedSession,
              let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return nil }
        workspaces[index].axis = axis
        if let other = workspace.secondarySessionID { return session(other) }
        let additional = makeSession(selected.profile)
        workspaces[index].secondarySessionID = additional.id
        workspaces[index].focusedSessionID = additional.id
        additional.start()
        return additional
    }

    func resizeSplit(_ workspaceID: UUID, fraction: Double) {
        guard fraction.isFinite, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].splitFraction = min(1, max(0, fraction))
    }

    private func synchronizeSplitPanels() {
        if selectedWorkspace?.axis == .columns, selectedWorkspace?.secondarySessionID != nil {
            // 仅在进入左右分屏时收起；之后允许用户手动展开，不因焦点或比例变化再次隐藏。
            if panelsBeforeColumnSplit == nil {
                panelsBeforeColumnSplit = (sidebarVisible, filesVisible)
                sidebarVisible = false
                filesVisible = false
            }
        } else if let previous = panelsBeforeColumnSplit {
            panelsBeforeColumnSplit = nil
            sidebarVisible = previous.sidebar
            filesVisible = previous.files
        }
    }

    func savePreferences(_ value: TerminalPreferences) throws {
        let validated = try value.validated()
        try settingsStore.save(validated)
        preferences = validated
        sessions.forEach { $0.applyPreferences(validated) }
    }

    func saveSettings(terminal: TerminalPreferences, transfer: TransferPreferences,
                      controller: TransferSettingsController) throws {
        let terminal = try terminal.validated()
        let transfer = try transfer.validated()
        _ = try settingsStore.load()
        _ = try controller.store.load()
        let previous: Data?
        do { previous = try Data(contentsOf: settingsStore.fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { previous = nil }
        try settingsStore.save(terminal)
        do { try controller.store.save(transfer) }
        catch {
            let saveError = error
            // 两份文件全部保存后才应用偏好；第二份失败时还原第一份的原始内容。
            do {
                if let previous { try previous.write(to: settingsStore.fileURL, options: .atomic) }
                else { try FileManager.default.removeItem(at: settingsStore.fileURL) }
            } catch {
                settingsError = "传输设置保存失败，终端设置也未能恢复。请检查设置文件后重启应用：\(settingsStore.fileURL.path)\n\(error.localizedDescription)"
                throw ProfileError("\(saveError.localizedDescription)\n\(settingsError!)")
            }
            throw saveError
        }
        preferences = terminal
        sessions.forEach { $0.applyPreferences(terminal) }
        controller.applyPreferences(transfer)
    }

    func perform(_ action: TerminalAction) {
        switch action {
        case .newConnection: newConnection()
        case .connect: if let profile = selectedProfile { connect(profile) }
        case .splitColumns: split(.columns)
        case .splitRows: split(.rows)
        case .nextPane: focusNextPane()
        case .find: selectedSession?.showFind()
        case .findNext: selectedSession?.showFind(.next)
        case .findPrevious: selectedSession?.showFind(.previous)
        case .increaseFont: selectedSession?.changeFontSize(by: 1)
        case .decreaseFont: selectedSession?.changeFontSize(by: -1)
        case .resetFont: selectedSession?.resetFontSize()
        case .toggleLog: selectedSession?.toggleLogging()
        case .closePane: if let session = selectedSession { close(session) }
        }
    }

    func canPerform(_ action: TerminalAction) -> Bool {
        guard !settingsPresented else { return false }
        switch action {
        case .newConnection: return storageError == nil
        case .connect: return selectedProfile != nil
        case .nextPane: return selectedWorkspace?.secondarySessionID != nil
        case .toggleLog: return selectedSession?.state == .connected
        default: return selectedSession != nil
        }
    }

    func closeWorkspace(_ workspace: TerminalWorkspace) {
        let targets = workspace.sessionIDs.compactMap { session($0) }
        if targets.contains(where: { $0.isRunning }) {
            guard Self.confirm(title: "关闭此标签的 \(targets.count) 个会话？", detail: "所有窗格的 SSH 连接将断开，远程任务可能中断。", action: "断开并关闭") else { return }
        }
        for target in targets { closeConfirmed(target) }
    }

    func close(_ session: TerminalSession) {
        if session.isRunning {
            guard Self.confirm(title: "关闭“\(session.profile.name)”？", detail: "SSH 连接将断开，前台运行的远程任务可能中断。", action: "断开并关闭") else { return }
        }
        closeConfirmed(session)
    }

    func closeConnections(_ profile: ConnectionProfile,
                          confirm: @MainActor (String, String, String) -> Bool = AppModel.confirm) {
        let targets = sessions.filter { $0.profile.id == profile.id }
        guard !targets.isEmpty else { return }
        if targets.contains(where: { $0.isRunning }) {
            guard confirm("关闭“\(profile.name)”的全部连接？",
                          "将关闭此配置的 \(targets.count) 个会话及对应标签/窗格。SSH 连接和文件传输将停止，前台远程任务可能中断；连接配置会保留，其他连接不受影响。",
                          "全部关闭") else { return }
        }
        // 确认前捕获具体会话；异步退出时沿用单窗格关闭的清理流程。
        targets.forEach(closeConfirmed)
    }

    private func closeConfirmed(_ session: TerminalSession) {
        session.stopLogging()
        if session.isRunning { closingIDs.insert(session.id); session.disconnect() }
        else { removeSession(session.id) }
    }

    func disconnectAll() {
        sessions.filter { $0.isRunning }.forEach { $0.disconnect() }
        // 确认框运行期间工作可能已经结束，此时不会再收到新的结束通知。
        notifyIfAllWorkEnded()
    }

    private func notifyIfAllWorkEnded() {
        guard !hasActiveWork, let completion = onAllSessionsEnded else { return }
        onAllSessionsEnded = nil
        completion()
    }

    func revealConfiguration() { NSWorkspace.shared.selectFile(store.fileURL.path, inFileViewerRootedAtPath: "") }

    private func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        sessionObservers.removeValue(forKey: id)
        if let index = workspaces.firstIndex(where: { $0.sessionIDs.contains(id) }) {
            let remaining = workspaces[index].sessionIDs.filter { $0 != id }
            if let survivor = remaining.first {
                workspaces[index].primarySessionID = survivor
                workspaces[index].secondarySessionID = nil
                workspaces[index].focusedSessionID = survivor
            } else {
                let removed = workspaces.remove(at: index)
                if selectedWorkspaceID == removed.id { selectedWorkspaceID = workspaces.last?.id }
            }
        }
    }

    static func confirm(title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
