import AppKit
import Combine
import SwiftTerm
import Nc2ShellCore

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, @preconcurrency TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
    enum State { case idle, connecting, connected, reconnecting, disconnecting, disconnected, failed }

    let id = UUID()
    let profile: ConnectionProfile
    let files = RemoteFilesModel()
    let directoryBookmarks: RemoteDirectoryBookmarks
    private(set) var directoryToken = "nc2-\(UUID().uuidString.lowercased()).invalid"
    @Published private(set) var state: State = .idle
    @Published private(set) var statusText = "尚未连接"
    @Published private(set) var remoteDirectory: RemoteDirectory?
    private(set) var shellContext: ShellContext?
    private var directoryMonitor: DirectoryFollowMonitor?
    private var directoryMonitorGeneration = UUID()
    private var observingOriginalShell = false
    private var originalDirectory: RemoteDirectory?
    @Published private(set) var terminal: SessionTerminalView {
        didSet { configureTerminal() }
    }
    @Published private(set) var theme: TerminalTheme = .midnight
    @Published private(set) var logURL: URL?
    @Published var logError: String?
    @Published private(set) var searchVisible = false
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var searchSummary = ""
    @Published var searchText = "" {
        didSet { if searchText != oldValue { updateSearch(reset: true) } }
    }
    @Published var searchOptions = SearchOptions() {
        didSet { if searchOptions != oldValue { updateSearch(reset: true) } }
    }
    var onEnded: (() -> Void)?
    private(set) var process: LocalProcess?
    private var controlDirectory: URL?
    private var connectionTimer: Timer?
    private var terminationTimer: Timer?
    private var fontSize: CGFloat = 18
    private var defaultFontSize: CGFloat = 18
    private var scrollbackLines = 10_000
    private var optionAsMetaKey = true
    private var outputLog: TerminalOutputLog?
    private var processDelegate: SessionProcessDelegate?
    private var lastOutputAt = ProcessInfo.processInfo.systemUptime
    private var processExitReceived = false
    private let outputHasEnded: (LocalProcess) -> Bool
    private let argumentBuilder: (ConnectionProfile, String) throws -> [String]
    private let askpassExecutable: URL
    private let credentials: ConnectionCredentials
    var temporaryPassword: String?
    private var passwordBroker: SSHPasswordBroker?
    private var usingProvidedPassword = false
    private var requestedRememberedPassword = true
    private var authenticatedProcess = false
    private var automaticReconnectUsed = false
    private var reconnectTimer: Timer?
    private var reconnectPreflight: SSHReconnectPreflight?
    private var reconnectGeneration = UUID()

    var isRunning: Bool { state == .connecting || state == .connected || state == .reconnecting || state == .disconnecting }
    var controlPath: String? { controlDirectory?.appendingPathComponent("s").path }

    convenience init(profile: ConnectionProfile, askpassExecutable: URL? = nil, credentials: ConnectionCredentials = KeychainCredentials(),
                     directoryBookmarks: RemoteDirectoryBookmarks? = nil,
                     argumentBuilder: @escaping (ConnectionProfile, String) throws -> [String] = SSHCommand.arguments) {
        self.init(profile: profile, outputHasEnded: { $0.childfd < 0 }, askpassExecutable: askpassExecutable, credentials: credentials,
                  directoryBookmarks: directoryBookmarks, argumentBuilder: argumentBuilder)
    }

    init(profile: ConnectionProfile, outputHasEnded: @escaping (LocalProcess) -> Bool,
         askpassExecutable: URL? = nil, credentials: ConnectionCredentials = KeychainCredentials(),
         directoryBookmarks: RemoteDirectoryBookmarks? = nil,
         argumentBuilder: @escaping (ConnectionProfile, String) throws -> [String] = SSHCommand.arguments) {
        self.profile = profile
        self.directoryBookmarks = directoryBookmarks ?? .shared
        self.argumentBuilder = argumentBuilder
        self.outputHasEnded = outputHasEnded
        self.askpassExecutable = askpassExecutable ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        self.credentials = credentials
        terminal = Self.makeTerminal(fontSize: 18)
        super.init()
        configureTerminal()
        files.onFollowingChanged = { [weak self] in self?.updateDirectoryMonitor() }
    }

    private func configureTerminal() {
        terminal.terminalDelegate = self
        terminal.onScrollbackReduced = { [weak self] in self?.searchSummary = "" }
    }

    func start(useRememberedPassword: Bool = true) {
        guard !isRunning else { return }
        reconnectTimer?.invalidate(); reconnectTimer = nil; reconnectGeneration = UUID()
        automaticReconnectUsed = false
        requestedRememberedPassword = useRememberedPassword
        startConnection(automatic: false)
    }

    private func startConnection(automatic: Bool) {
        guard !isRunning else { return }
        stopLogging()
        authenticatedProcess = false
        do {
            let profile = try profile.validated()
            if !profile.identityFile.isEmpty {
                let path = (profile.identityFile as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
                    throw ProfileError("无法读取私钥文件，请检查路径。")
                }
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-\(UUID().uuidString.prefix(12))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            controlDirectory = directory
            directoryToken = "nc2-\(UUID().uuidString.lowercased()).invalid"
            let controlPath = directory.appendingPathComponent("s").path
            // 初始化属于 SSH 的远端启动命令，不向密码提示或交互 Shell 投递输入。
            usingProvidedPassword = (profile.rememberPassword || temporaryPassword != nil) && requestedRememberedPassword
            let authentication = usingProvidedPassword ? SSHCommand.rememberedPasswordOptions : []
            let automaticOptions = automatic ? SSHCommand.automaticReconnectOptions(usingRememberedPassword: usingProvidedPassword) : []
            let arguments = automaticOptions + authentication + ["-o", "RemoteCommand=none"] + (try argumentBuilder(profile, controlPath)) + [ShellIntegration.bootstrapCommand(token: directoryToken)]
            if usingProvidedPassword {
                passwordBroker = try SSHPasswordBroker(directory: directory, profile: profile, executable: askpassExecutable,
                                                       credentials: credentials, password: temporaryPassword, allowsInteractivePrompts: !automatic)
            }
            if automatic {
                // 保留可见文字用于回看，但不能把旧 vim/OSC/鼠标模式带入新的 SSH。
                let previous = terminal.getTerminal()
                var history = String(decoding: previous.getBufferAsData(kind: .normal), as: UTF8.self)
                if previous.isCurrentBufferAlternate {
                    history += "\n[断线前的全屏内容]\n" + String(decoding: previous.getBufferAsData(kind: .alt), as: UTF8.self)
                }
                let plain = String(history.unicodeScalars.filter { $0.value == 10 || ($0.value >= 32 && !((127...159).contains($0.value))) })
                    .trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: "\r\n")
                let frame = terminal.frame
                terminal = Self.makeTerminal(fontSize: fontSize, theme: theme, scrollbackLines: scrollbackLines, optionAsMetaKey: optionAsMetaKey)
                terminal.frame = frame
                terminal.feed(text: plain)
                terminal.feed(text: "\r\n[Nc2Shell 正在尝试自动重连，不会重放命令]\r\n")
            } else {
                terminal = Self.makeTerminal(fontSize: fontSize, theme: theme, scrollbackLines: scrollbackLines, optionAsMetaKey: optionAsMetaKey)
            }
            searchText = ""
            searchSummary = ""
            searchVisible = false
            remoteDirectory = nil
            shellContext = nil
            originalDirectory = nil
            // SwiftTerm 默认主队列会把输出延后分片，退出通知可能早于末尾输出。
            // 使用仍在主线程执行的独立串行队列，让每块输出同步交付，再等待 PTY EOF 收尾。
            let outputQueue = DispatchQueue(label: "Nc2Shell.output.\(id)", target: .main)
            let delegate = SessionProcessDelegate(owner: self)
            let child = LocalProcess(delegate: delegate, dispatchQueue: outputQueue)
            delegate.process = child
            processDelegate = delegate
            process = child
            processExitReceived = false
            state = .connecting
            statusText = automatic ? "正在自动重连 · 本次最多尝试一次" : "连接中 · 请留意终端中的登录提示"
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
            environment.removeValue(forKey: SSHAskpass.environmentKey)
            if let passwordBroker {
                environment["SSH_ASKPASS"] = askpassExecutable.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment[SSHAskpass.environmentKey] = passwordBroker.socketPath
            } else if automatic {
                // SSH 子进程也继承拒绝提示的助手，不能回退到当前 PTY 等待认证。
                environment["SSH_ASKPASS"] = "/usr/bin/false"
                environment["SSH_ASKPASS_REQUIRE"] = "force"
            } else if !requestedRememberedPassword {
                environment["SSH_ASKPASS_REQUIRE"] = "never"
            }
            child.startProcess(executable: "/usr/bin/ssh", args: arguments, environment: environment.map { "\($0.key)=\($0.value)" })
            guard child.running else { throw ProfileError("无法启动 SSH 终端进程。") }
            passwordBroker?.start(sshPID: child.shellPid)
            // socket 只在 SSH 完成认证后建立，不能把进程启动当成连接成功。
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .connecting else { return }
                    if FileManager.default.fileExists(atPath: controlPath) {
                        self.authenticatedProcess = true
                        self.state = .connected
                        self.statusText = "已连接"
                        self.passwordBroker?.stop()
                        self.passwordBroker = nil
                        // 首个提示符可能早于认证轮询，不能在文件面板初始化时丢掉已收到的路径。
                        self.files.connect(profile: self.profile, controlPath: controlPath, initialDirectory: self.files.reportedPath)
                        self.connectionTimer?.invalidate()
                        self.connectionTimer = nil
                    }
                }
            }
            connectionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            state = .failed
            statusText = error.localizedDescription
            cleanup()
            if automatic { onEnded?() }
        }
    }

    func disconnect() {
        stopLogging()
        if state == .reconnecting {
            reconnectTimer?.invalidate(); reconnectTimer = nil; reconnectGeneration = UUID()
            reconnectPreflight?.cancel(); reconnectPreflight = nil
            state = .disconnected; statusText = "已取消自动重连"
            cleanup(); onEnded?()
            return
        }
        if state == .disconnecting, processExitReceived, let process {
            finishTermination(process, exitCode: nil, requested: true)
            return
        }
        guard isRunning, state != .disconnecting, let process else { return }
        state = .disconnecting
        passwordBroker?.stop()
        passwordBroker = nil
        files.disconnect()
        statusText = "正在断开…"
        connectionTimer?.invalidate()
        connectionTimer = nil
        let pid = process.shellPid
        guard pid > 0 else { return }
        // 保留 SwiftTerm 的退出监视器，让它回收子进程，避免 terminate() 提前取消监视导致僵尸进程。
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak process] in
            guard let self, let process, self.process === process, process.running else { return }
            kill(pid, SIGKILL)
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        // 延后一轮，避免在 SwiftTerm 尚未结束旧进程清理时启动新会话。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.process === source, !self.processExitReceived else { return }
            self.processExitReceived = true
            let requested = self.state == .disconnecting
            self.state = .disconnecting
            self.statusText = "正在接收会话末尾输出…"
            self.connectionTimer?.invalidate()
            self.connectionTimer = nil
            self.lastOutputAt = ProcessInfo.processInfo.systemUptime
            if requested || self.outputHasEnded(source) {
                self.finishTermination(source, exitCode: exitCode, requested: requested)
            } else {
                let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self, weak source] _ in
                    MainActor.assumeIsolated {
                        guard let self, let source, self.process === source else { return }
                        if self.outputHasEnded(source) {
                            self.finishTermination(source, exitCode: exitCode, requested: requested)
                        } else if ProcessInfo.processInfo.systemUptime - self.lastOutputAt >= 5 {
                            self.finishTermination(source, exitCode: exitCode, requested: requested, incompleteOutput: true)
                        }
                    }
                }
                self.terminationTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func finishTermination(_ source: LocalProcess, exitCode: Int32?, requested: Bool, incompleteOutput: Bool = false) {
        guard process === source else { return }
        let shouldReconnect = profile.autoReconnect && authenticatedProcess && !automaticReconnectUsed
            && !requested && !incompleteOutput && Self.normalExitCode(exitCode) == 255
        state = !incompleteOutput && (requested || exitCode == 0) ? .disconnected : .failed
        statusText = incompleteOutput ? "连接已结束，但末尾输出未能确认完整" : state == .disconnected ? "已断开" : "连接结束 · 请查看终端中的错误提示"
        if state == .failed, usingProvidedPassword, !incompleteOutput {
            statusText += "；预填密码最多尝试一次，可更新密码或手动认证重连"
        }
        if incompleteOutput, outputLog != nil { logError = "进程已退出，但输出通道连续 5 秒没有数据且未结束；日志尾部可能不完整。" }
        // 先断开委托，迟到回调不能进入重连后的终端；释放 IO 时绝不再次 kill 已回收的 PID。
        processDelegate = nil
        if requested || incompleteOutput { process = nil }
        remoteDirectory = nil
        cleanup()
        if shouldReconnect {
            automaticReconnectUsed = true
            state = .reconnecting
            statusText = "3 秒后尝试自动重连 · 本次最多一次"
            let generation = UUID(); reconnectGeneration = generation
            let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .reconnecting, self.reconnectGeneration == generation else { return }
                    self.reconnectTimer = nil
                    self.checkAutomaticReconnect(generation: generation)
                }
            }
            reconnectTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        onEnded?()
    }

    static func normalExitCode(_ status: Int32?) -> Int32? {
        // SwiftTerm 1.18 传递 waitpid 原始状态；信号/停止/未知状态不能当作 SSH 退出码。
        guard let status, (0...0xffff).contains(status), status & 0xff == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    private func checkAutomaticReconnect(generation: UUID) {
        let check = SSHReconnectPreflight()
        reconnectPreflight = check
        statusText = "正在检查自动重连配置…"
        Task {
            do {
                let arguments = try argumentBuilder(profile.validated(), "/tmp/nc2-configuration-check")
                try await check.run(arguments: arguments)
                guard state == .reconnecting, reconnectGeneration == generation else { return }
                reconnectPreflight = nil
                state = .disconnected
                startConnection(automatic: true)
            } catch {
                guard state == .reconnecting, reconnectGeneration == generation else { return }
                reconnectPreflight = nil
                state = .failed; statusText = error.localizedDescription
                onEnded?()
            }
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutputAt = ProcessInfo.processInfo.systemUptime
        // 仅此远端输出入口写日志；按键、粘贴和密码输入不进入日志器。
        if let outputLog {
            do { try outputLog.append(slice) }
            catch {
                logError = "日志写入失败，已停止记录；终端仍可使用：\(error.localizedDescription)"
                stopLogging()
            }
        }
        terminal.feed(byteArray: slice)
    }

    func getWindowSize() -> winsize {
        let screen = terminal.getTerminal()
        return winsize(ws_row: UInt16(clamping: screen.rows), ws_col: UInt16(clamping: screen.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let process, process.running else { return }
        var size = getWindowSize()
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard process?.running == true else { return }
        process?.send(data: data)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard source === terminal else { return }
        if let directory, let context = ShellContext.parse(report: directory, token: directoryToken) {
            if shellContext == nil {
                shellContext = context
                updateDirectoryMonitor()
            }
            return
        }
        remoteDirectory = directory.flatMap(RemoteDirectory.parse)
        if let report = remoteDirectory, report.host == directoryToken {
            originalDirectory = report
            if observingOriginalShell || state != .connected || !files.following || shellContext == nil { files.follow(report.path) }
        }
    }

    private func stopDirectoryMonitor() {
        directoryMonitorGeneration = UUID()
        directoryMonitor?.cancel(); directoryMonitor = nil
        observingOriginalShell = false
    }

    private func updateDirectoryMonitor() {
        guard state == .connected, files.isConnected, files.following, let shellContext, let controlPath else {
            stopDirectoryMonitor(); return
        }
        guard directoryMonitor == nil else { return }
        let generation = UUID(); directoryMonitorGeneration = generation
        files.suspendFollowing(reason: "正在确认终端当前环境…")
        do {
            let monitor = try DirectoryFollowMonitor(profile: profile, controlPath: controlPath, context: shellContext, token: directoryToken)
            directoryMonitor = monitor
            monitor.start { [weak self] result in
                Task { @MainActor in
                    guard let self, self.directoryMonitorGeneration == generation, self.state == .connected, self.files.following else { return }
                    switch result {
                    case .success(.original):
                        if !self.observingOriginalShell { self.files.resumeFollowing(path: self.originalDirectory?.path) }
                        self.observingOriginalShell = true
                    case .success(.tmux(let path)):
                        self.observingOriginalShell = false
                        self.remoteDirectory = RemoteDirectory(host: self.profile.host, path: path)
                        self.files.resumeFollowing(path: path)
                    case .success(.paused(let reason)):
                        self.observingOriginalShell = false
                        self.files.suspendFollowing(reason: reason.message)
                    case .failure(let error):
                        self.stopDirectoryMonitor()
                        self.files.suspendFollowing(reason: error.localizedDescription)
                    }
                }
            }
        } catch { files.suspendFollowing(reason: error.localizedDescription) }
    }

    // 远端标题不覆盖用户保存的连接名称；滚动与绘制完全交给终端组件。
    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // Cmd+C / Cmd+V 仍由终端视图处理；禁止远端 OSC52 主动获取或改写本机剪贴板。
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func clipboardCopy(source: TerminalView, content: Data) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    func changeFontSize(by amount: CGFloat) {
        fontSize = min(28, max(10, fontSize + amount))
        terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .light)
    }

    func resetFontSize() {
        fontSize = defaultFontSize
        terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .light)
    }

    func applyPreferences(_ preferences: TerminalPreferences) {
        let themeChanged = theme != preferences.theme
        theme = preferences.theme
        defaultFontSize = preferences.fontSize
        if fontSize != defaultFontSize { resetFontSize() }
        scrollbackLines = preferences.scrollbackLines
        optionAsMetaKey = preferences.optionAsMetaKey
        terminal.setScrollback(scrollbackLines)
        terminal.optionAsMetaKey = optionAsMetaKey
        // 未改主题时不重新安装色板，避免无关设置重置远端通过OSC设置的颜色。
        if themeChanged {
            terminal.nativeBackgroundColor = theme.background
            terminal.nativeForegroundColor = theme.foreground
            terminal.caretColor = theme.caret
            terminal.installColors(theme.ansiColors)
        }
    }

    func showFind(_ action: NSFindPanelAction = .showFindPanel) {
        if action == .showFindPanel || searchText.isEmpty {
            if !searchVisible && !searchText.isEmpty { updateSearch(reset: true) }
            searchVisible = true
            searchFocusRequest += 1
        } else {
            updateSearch(forward: action != .previous)
        }
    }

    func closeSearch() {
        searchVisible = false
        searchSummary = ""
        terminal.clearSearch()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.searchVisible else { return }
            self.terminal.window?.makeFirstResponder(self.terminal)
        }
    }

    private func updateSearch(forward: Bool = true, reset: Bool = false) {
        if reset { terminal.clearSearch() }
        guard !searchText.isEmpty else { searchSummary = ""; return }
        if searchOptions.regex, (try? NSRegularExpression(pattern: searchText)) == nil {
            searchSummary = "正则表达式无效"
            return
        }
        let found = forward ? terminal.findNext(searchText, options: searchOptions) : terminal.findPrevious(searchText, options: searchOptions)
        let summary = terminal.searchMatchSummary(searchText, options: searchOptions)
        searchSummary = found ? "\(summary.index) / \(summary.total == 1000 ? "≥1000" : String(summary.total))" : "无匹配"
    }

    func startLogging(to url: URL) throws {
        guard state == .connected, outputLog == nil else { throw ProfileError("请在已连接且尚未记录日志的会话中开始。") }
        outputLog = try TerminalOutputLog(fileURL: url)
        logError = nil
        logURL = url
    }

    func stopLogging() {
        let log = outputLog
        outputLog = nil
        logURL = nil
        do { try log?.close() }
        catch { logError = "日志结束时写入失败：\(error.localizedDescription)" }
    }

    func toggleLogging() {
        if outputLog != nil { stopLogging(); return }
        guard state == .connected else { return }
        let processAtSelection = process
        let panel = NSSavePanel()
        panel.title = "保存会话日志"
        panel.message = "选择新的本机文本文件，不覆盖已有文件。仅记录之后收到的远端输出；输出可能含敏感信息。日志不是完整终端录像。"
        panel.nameFieldStringValue = "Nc2Shell-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).log"
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard self.process === processAtSelection, self.state == .connected else {
                self.logError = "选择文件期间会话已变化，请重新开始日志。"
                return
            }
            do { try self.startLogging(to: url) }
            catch { self.logError = error.localizedDescription }
        }
        if let window = terminal.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    private static func makeTerminal(fontSize: CGFloat, theme: TerminalTheme = .midnight,
                                     scrollbackLines: Int = 10_000, optionAsMetaKey: Bool = true) -> SessionTerminalView {
        let view = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 880, height: 560),
                                font: .monospacedSystemFont(ofSize: fontSize, weight: .light),
                                options: TerminalOptions(scrollback: scrollbackLines))
        view.setScrollback(scrollbackLines)
        view.optionAsMetaKey = optionAsMetaKey
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.caretColor = theme.caret
        view.installColors(theme.ansiColors)
        return view
    }

    private func cleanup() {
        stopDirectoryMonitor()
        passwordBroker?.stop()
        passwordBroker = nil
        stopLogging()
        processDelegate = nil
        terminationTimer?.invalidate()
        terminationTimer = nil
        files.disconnect()
        connectionTimer?.invalidate()
        connectionTimer = nil
        if let directory = controlDirectory { try? FileManager.default.removeItem(at: directory) }
        controlDirectory = nil
    }

    deinit {
        directoryMonitor?.cancel()
        passwordBroker?.stop()
        connectionTimer?.invalidate()
        terminationTimer?.invalidate()
        reconnectTimer?.invalidate()
        reconnectPreflight?.cancel()
        if let process, process.running, process.shellPid > 0 {
            let pid = process.shellPid
            kill(pid, SIGTERM)
            DispatchQueue.global().async { var status: Int32 = 0; waitpid(pid, &status, 0) }
        }
        if let directory = controlDirectory { try? FileManager.default.removeItem(at: directory) }
    }
}

final class SessionTerminalView: TerminalView {
    private var preferredScrollbackLines: Int?
    var onScrollbackReduced: (() -> Void)?

    func setScrollback(_ lines: Int) {
        preferredScrollbackLines = lines
        bufferActivated(source: getTerminal())
    }

    override func bufferActivated(source: Terminal) {
        if let lines = preferredScrollbackLines, !source.isCurrentBufferAlternate, source.options.scrollback != lines {
            // SwiftTerm 裁剪会把屏幕相对 savedY 当成历史行号递减；保留它，避免光标恢复后覆盖新输出。
            // 备用屏幕期间延后调整，返回普通屏幕后才可安全访问对应的光标状态。
            let savedRow = source.buffer.savedY
            if lines < source.options.scrollback {
                // 选区使用绝对缓冲行号，裁剪后不能继续指向原来的行号。
                clearSearch()
                onScrollbackReduced?()
            }
            changeScrollback(lines)
            source.buffer.savedY = savedRow
        }
        super.bufferActivated(source: source)
    }
}

@MainActor
final class SessionProcessDelegate: @preconcurrency LocalProcessDelegate {
    private weak var owner: TerminalSession?
    weak var process: LocalProcess?

    init(owner: TerminalSession) { self.owner = owner }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard let owner, let process, owner.process === process else { return }
        owner.dataReceived(slice: slice)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { owner?.processTerminated(source, exitCode: exitCode) }
    func getWindowSize() -> winsize { owner?.getWindowSize() ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
}
