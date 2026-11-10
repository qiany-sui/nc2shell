import SwiftUI
import AppKit
import Nc2ShellCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var sidebarWidth: CGFloat = 280
    @State private var showTransfers = false
    @FocusState private var connectionSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    connectionSidebar.frame(width: sidebarWidth)
                    WorkspaceDivider(width: $sidebarWidth, limits: 260...340, label: "调整连接栏宽度")
                }
                VStack(spacing: 0) {
                    workspaceHeader
                    Rectangle().fill(WorkspaceAppearance.line).frame(height: 1)
                    if let workspace = model.selectedWorkspace {
                        TerminalWorkspaceView(model: model, workspace: workspace, showFiles: $model.filesVisible,
                                              showTransfers: { showTransfers = true }).id(workspace.id)
                    } else { welcome }
                    if showTransfers {
                        Rectangle().fill(WorkspaceAppearance.line).frame(height: 1)
                        VStack(spacing: 0) {
                            HStack {
                                Text("传输管理").font(.headline)
                                Spacer()
                                Button { showTransfers = false } label: { Image(systemName: "xmark") }
                                    .buttonStyle(WorkspaceIconButton()).help("收起传输管理")
                            }.padding(.horizontal, 16).padding(.top, 4)
                            TransferQueueView(model: model)
                        }.frame(minHeight: 150, idealHeight: 220, maxHeight: 300)
                            .background(WorkspaceAppearance.panel)
                    }
                }.frame(minWidth: 580, maxWidth: .infinity)
            }
            Rectangle().fill(WorkspaceAppearance.line).frame(height: 1)
            HStack(spacing: 0) {
                if let session = model.selectedSession { WorkspaceStatus(session: session) }
                else {
                    Circle().fill(.gray).frame(width: 7, height: 7)
                    Text("尚未连接").padding(.leading, 9)
                }
                Spacer(minLength: 8)
                Button { showTransfers.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }
                    .buttonStyle(WorkspaceIconButton()).help("传输管理与待恢复任务")
                    .accessibilityLabel("传输管理")
                Text("0.12.21").font(.system(size: 11)).foregroundStyle(WorkspaceAppearance.secondary)
            }.font(.system(size: 13)).foregroundStyle(WorkspaceAppearance.secondary)
                .padding(.horizontal, 18).frame(height: 42).background(WorkspaceAppearance.panel)
        }
        .background(Color(nsColor: WorkspaceAppearance.terminal))
        .background(WorkspaceWindowChrome())
        .foregroundStyle(WorkspaceAppearance.text).tint(WorkspaceAppearance.accent)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.sidebarVisible) { _, visible in
            if !visible, let session = model.selectedSession { model.focus(session.id) }
        }
        .sheet(item: $model.editor) { profile in
            ConnectionEditor(profile: profile, hasTemporaryPassword: model.hasTemporaryPassword(for: profile), onSave: model.save)
        }
        .sheet(isPresented: $model.settingsPresented, onDismiss: {
            if let session = model.selectedSession { model.focus(session.id) }
        }) {
            WorkspaceSettingsView(model: model, transferSettings: model.transferSettings ?? .shared)
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .frame(minWidth: max(980, (model.sidebarVisible ? sidebarWidth : 0) + (model.selectedWorkspace?.secondarySessionID == nil ? 580 : (model.filesVisible ? 781 : 480))), minHeight: 600)
    }

    private var connectionSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Nc2Shell").font(.system(size: 18, weight: .regular)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Button { model.sidebarVisible = false } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(WorkspaceIconButton()).help("收拢连接栏").accessibilityLabel("收拢连接栏")
            }.padding(.leading, 96).padding(.trailing, 14).frame(height: WorkspaceAppearance.headerHeight)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkspaceAppearance.secondary)
                TextField("搜索连接", text: $model.connectionQuery).textFieldStyle(.plain)
                    .focused($connectionSearchFocused)
                    .onExitCommand {
                        model.connectionQuery = ""
                        connectionSearchFocused = false
                        DispatchQueue.main.async {
                            if let session = model.selectedSession { model.focus(session.id) }
                        }
                    }
                    .accessibilityLabel("按名称、主机或用户名搜索连接")
                if !model.connectionQuery.isEmpty {
                    Button { model.connectionQuery = ""; connectionSearchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                            .foregroundStyle(WorkspaceAppearance.secondary)
                    }.buttonStyle(WorkspaceIconButton()).help("清除连接搜索").accessibilityLabel("清除连接搜索")
                }
            }.font(.system(size: 15)).padding(.leading, 12).padding(.trailing, 4).frame(height: 42)
                .background(WorkspaceAppearance.inputFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(connectionSearchFocused ? WorkspaceAppearance.accent.opacity(0.65) : WorkspaceAppearance.inputBorder))
                .padding(.horizontal, 14).padding(.top, 8)
            HStack {
                Text("连接").font(.system(size: 13)).foregroundStyle(WorkspaceAppearance.secondary)
                Spacer()
                if !model.connectionQuery.isEmpty {
                    Text("\(model.filteredProfiles.count) / \(model.profiles.count)")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(WorkspaceAppearance.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)
            List(selection: $model.selectedProfileID) {
                ForEach(model.filteredProfiles) { profile in
                    connectionRow(profile).tag(profile.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .contextMenu { connectionMenu(profile) }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .overlay(alignment: .top) {
                    if !model.connectionQuery.isEmpty, model.filteredProfiles.isEmpty, model.storageError == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light))
                            Text("未找到匹配连接").font(.system(size: 14))
                            Button("清除搜索") { model.connectionQuery = ""; connectionSearchFocused = true }
                                .buttonStyle(.plain).foregroundStyle(WorkspaceAppearance.accent)
                        }.foregroundStyle(WorkspaceAppearance.secondary).padding(.top, 30)
                    }
                }
            if let error = model.storageError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("查看配置文件") { model.revealConfiguration() }
                }.padding(12)
            }
            Rectangle().fill(WorkspaceAppearance.line).frame(height: 1)
            HStack {
                Button(action: model.newConnection) { Label("新建连接", systemImage: "plus").font(.system(size: 15)) }
                    .buttonStyle(.plain).disabled(model.storageError != nil)
                Spacer()
                Button(action: model.showSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(WorkspaceIconButton()).help("设置")
                    .accessibilityLabel("设置")
            }.padding(.horizontal, 18).frame(height: 58)
        }.background(WorkspaceAppearance.sidebar)
    }

    private func connectionRow(_ profile: ConnectionProfile) -> some View {
        let connected = model.sessions.contains { $0.profile.id == profile.id && $0.state == .connected }
        let pending = model.sessions.last { $0.profile.id == profile.id && ($0.state == .connecting || $0.state == .reconnecting) }
        let selected = model.selectedProfileID == profile.id
        let active = model.selectedSession?.profile.id == profile.id
        let compact = sidebarWidth < 280
        return HStack(spacing: compact ? 8 : 10) {
            Image(systemName: "server.rack").font(.system(size: 20, weight: .light)).frame(width: 24).foregroundStyle(WorkspaceAppearance.text)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if pending != nil {
                        ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 10, height: 10).accessibilityHidden(true)
                    } else {
                        Circle().fill(connected ? Color.green : WorkspaceAppearance.secondary).frame(width: 6, height: 6)
                    }
                    Text(profile.name).font(.system(size: 15, weight: .regular)).lineLimit(1).help(profile.name)
                    if let pending {
                        Text(pending.state == .reconnecting ? "重连中" : "连接中")
                            .font(.system(size: 10)).foregroundStyle(WorkspaceAppearance.accent).fixedSize()
                    } else if active { Text("当前").font(.system(size: 10)).foregroundStyle(WorkspaceAppearance.accent).fixedSize() }
                }
                Text(profile.destination).font(.system(size: 13)).foregroundStyle(WorkspaceAppearance.secondary)
                    .lineLimit(1).truncationMode(.middle).help(profile.destination)
            }
            Spacer(minLength: 0)
            Button {
                // 连点可能早于界面刷新，执行时再次检查当前状态。
                guard !model.sessions.contains(where: { $0.profile.id == profile.id && ($0.state == .connecting || $0.state == .reconnecting) }) else { return }
                model.connect(profile)
            } label: { Image(systemName: "play").font(.system(size: 15)) }
                .buttonStyle(WorkspaceIconButton()).disabled(pending != nil)
                .help(pending == nil ? "新建“\(profile.name)”连接会话" : "此连接正在连接，请稍候或在终端上方取消")
                .accessibilityLabel("连接 \(profile.name)")
            Menu { connectionMenu(profile) } label: { Image(systemName: "ellipsis").font(.system(size: 16)) }
                .menuStyle(.button).buttonStyle(WorkspaceIconButton()).menuIndicator(.hidden)
                .tint(WorkspaceAppearance.text).fixedSize().help("管理 \(profile.name)")
        }.padding(.leading, compact ? 14 : 20).padding(.trailing, compact ? 10 : 18).frame(height: 66)
            .background(ConnectionSelectionAppearance())
            .background(selected ? WorkspaceAppearance.selected : .clear)
            .overlay(alignment: .leading) { Rectangle().fill(active ? WorkspaceAppearance.accent : .clear).frame(width: 5) }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.selectedProfileID = profile.id
                // 双击与连接按钮遵循同一规则，不能重复创建仍在认证的会话。
                guard !model.sessions.contains(where: { $0.profile.id == profile.id && ($0.state == .connecting || $0.state == .reconnecting) }) else { return }
                model.connect(profile)
            }
            .onTapGesture { model.selectedProfileID = profile.id }
    }

    @ViewBuilder private func connectionMenu(_ profile: ConnectionProfile) -> some View {
        Button("连接") {
            // 菜单展开后状态仍可能变化，执行时再次检查，避免重复建连。
            guard !model.sessions.contains(where: { $0.profile.id == profile.id && ($0.state == .connecting || $0.state == .reconnecting) }) else { return }
            model.connect(profile)
        }.disabled(model.sessions.contains { $0.profile.id == profile.id && ($0.state == .connecting || $0.state == .reconnecting) })
        if model.sessions.contains(where: { $0.profile.id == profile.id }) {
            Button("关闭连接…") { model.closeConnections(profile) }
        }
        Button("编辑连接…") { model.editor = profile }
        Divider()
        Button("删除连接…", role: .destructive) { model.delete(profile) }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 0) {
            if !model.sidebarVisible {
                Button { model.sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(WorkspaceIconButton()).help("展开连接栏").accessibilityLabel("展开连接栏")
                    .padding(.leading, 96).padding(.trailing, 12)
            }
            workspaceTabs
            Button {
                if let profile = model.workspaceProfile ?? model.selectedSession?.profile { model.connect(profile) }
                else { model.newConnection() }
            } label: { Image(systemName: "plus") }
                .buttonStyle(WorkspaceIconButton()).padding(.horizontal, 4)
                .help((model.workspaceProfile ?? model.selectedSession?.profile).map { "新建“\($0.name)”会话" } ?? "新建连接")
                .accessibilityLabel("新建会话")
                .disabled(model.workspaceProfile == nil && model.selectedSession == nil && model.storageError != nil)
            if !model.workspaces.isEmpty {
                Menu {
                    ForEach(model.workspaces) { workspace in
                        if let session = model.session(workspace.primarySessionID) {
                            Button { model.selectWorkspace(workspace.id) } label: {
                                Label("\(model.workspaceTitle(workspace)) · \(session.profile.destination)",
                                      systemImage: workspace.id == model.selectedWorkspaceID ? "checkmark" : "terminal")
                            }
                        }
                    }
                } label: { Image(systemName: "chevron.down").font(.system(size: 12)).frame(width: 32, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .tint(WorkspaceAppearance.text).help("所有会话").accessibilityLabel("所有会话")
            }
            Rectangle().fill(WorkspaceAppearance.line).frame(width: 1, height: 16).padding(.horizontal, 10)
            HStack(spacing: 4) {
                Button { model.split() } label: { Image(systemName: "rectangle.split.1x2") }
                    .buttonStyle(WorkspaceIconButton()).help("上下分屏").accessibilityLabel("上下分屏")
                    .disabled(model.selectedSession == nil)
                Menu {
                    Button("上下分屏") { model.split(.rows) }
                    Button("左右分屏") { model.split(.columns) }
                    if model.selectedWorkspace?.secondarySessionID != nil {
                        Button("切换窗格") { model.perform(.nextPane) }
                        Button("关闭当前窗格") { model.perform(.closePane) }
                    }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().font(.system(size: 10)).foregroundStyle(WorkspaceAppearance.text).tint(WorkspaceAppearance.text).frame(width: 16, height: 32)
                    .help("分屏与窗格").accessibilityLabel("分屏与窗格").disabled(model.selectedSession == nil)
                Button { model.selectedSession?.showFind() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(WorkspaceIconButton()).help("查找终端内容").disabled(model.selectedSession == nil)
                Button { model.filesVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(WorkspaceIconButton()).help(model.filesVisible ? "收起文件面板" : "展开文件面板")
                    .accessibilityLabel(model.filesVisible ? "收起文件面板" : "展开文件面板").disabled(model.selectedSession == nil)
                Menu {
                    if let session = model.selectedSession {
                        Button(session.logURL == nil ? "开始会话日志…" : "停止会话日志") { session.toggleLogging() }
                            .disabled(session.state != .connected)
                        if session.state == .reconnecting {
                            Button("取消自动重连", action: session.disconnect)
                        } else if session.isRunning {
                            Button("断开当前连接…") {
                                if AppModel.confirm(title: "断开当前连接？", detail: "前台运行的远程任务可能中断。", action: "断开") { session.disconnect() }
                            }
                        } else {
                            Button("重新连接") { session.start() }
                            Button("手动认证重新连接") { session.start(useRememberedPassword: false) }
                        }
                        Button("关闭当前窗格") { model.close(session) }
                        Divider()
                    }
                    Button("传输管理与待恢复任务") { showTransfers.toggle() }
                    if let profile = model.workspaceProfile { Button("编辑“\(profile.name)”连接…") { model.editor = profile } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().font(.system(size: 16)).foregroundStyle(WorkspaceAppearance.text).tint(WorkspaceAppearance.text).frame(width: 32, height: 32).help("更多操作")
            }
        }.padding(.trailing, 14).frame(height: WorkspaceAppearance.headerHeight).background(WorkspaceAppearance.panel)
    }

    private var workspaceTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.workspaces) { workspace in
                        if let session = model.session(workspace.primarySessionID) {
                            SessionTab(session: session, title: model.workspaceTitle(workspace), selected: workspace.id == model.selectedWorkspaceID,
                                       split: workspace.secondarySessionID != nil,
                                       select: { model.selectWorkspace(workspace.id) }, close: { model.closeWorkspace(workspace) })
                                .id(workspace.id)
                        }
                    }
                }.padding(.leading, 12)
            }
            .onAppear { revealSelectedTab(proxy) }
            .onChange(of: model.selectedWorkspaceID) { _, _ in revealSelectedTab(proxy) }
            .onChange(of: model.workspaces.map(\.id)) { _, _ in revealSelectedTab(proxy) }
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width) { _, _ in revealSelectedTab(proxy) }
            })
        }
    }

    private func revealSelectedTab(_ proxy: ScrollViewProxy) {
        // 新标签先完成布局，再滚入视口；新建按钮固定在滚动区外。
        DispatchQueue.main.async {
            if let id = model.selectedWorkspaceID { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal").font(.system(size: 40, weight: .light)).foregroundStyle(WorkspaceAppearance.accent)
            Text(model.selectedProfile?.name ?? "从一次连接开始").font(.system(size: 24, weight: .semibold))
            Text(model.selectedProfile?.destination ?? "选择左侧连接，或添加一台服务器。")
                .foregroundStyle(WorkspaceAppearance.secondary).textSelection(.enabled)
            if let profile = model.selectedProfile {
                Button("连接服务器") { model.connect(profile) }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button("新建连接", action: model.newConnection).buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.storageError != nil)
            }
            if let count = model.recovery?.pendingRecords.count, count > 0 {
                Button("查看 \(count) 项待恢复传输") { showTransfers = true }
            } else if model.recovery?.error != nil { Button("查看恢复记录错误") { showTransfers = true } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionTab: View {
    @ObservedObject var session: TerminalSession
    let title: String
    let selected: Bool
    let split: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        let pending = session.state == .connecting || session.state == .reconnecting
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 8) {
                    if pending {
                        ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 10, height: 10).accessibilityHidden(true)
                    } else {
                        Circle().fill(session.state == .connected ? Color.green : session.state == .failed ? WorkspaceAppearance.accent : WorkspaceAppearance.secondary).frame(width: 7, height: 7)
                    }
                    Text(title).font(.system(size: 15, weight: .regular)).lineLimit(1)
                    if pending {
                        Text(session.state == .reconnecting ? "重连中" : "连接中")
                            .font(.system(size: 11)).foregroundStyle(WorkspaceAppearance.accent).fixedSize()
                    }
                    if split { Image(systemName: "rectangle.split.2x1").font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: WorkspaceAppearance.headerHeight - 5).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(title)\n\(session.profile.destination) · 端口 \(String(session.profile.port))")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)) }
                .buttonStyle(WorkspaceIconButton()).help("关闭此标签的所有窗格")
                .accessibilityLabel("关闭 \(title) 标签")
        }.padding(.leading, 16).padding(.trailing, 8).frame(minWidth: 170, maxWidth: 250)
            .foregroundStyle(selected ? WorkspaceAppearance.text : WorkspaceAppearance.secondary)
            .background(selected ? Color.white.opacity(0.03) : .clear,
                        in: UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? WorkspaceAppearance.accent : .clear).frame(height: 4) }
            .overlay(alignment: .trailing) { Rectangle().fill(WorkspaceAppearance.line).frame(width: 1) }
            .padding(.top, 4)
    }
}

private struct WorkspaceStatus: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(session.state == .connected ? Color.green : session.state == .failed ? Color.orange : Color.gray).frame(width: 7, height: 7)
            Text(session.statusText).lineLimit(1).help(session.statusText)
            if session.state == .reconnecting {
                Button("取消重连", action: session.disconnect).buttonStyle(.plain)
            }
            Rectangle().fill(WorkspaceAppearance.line).frame(width: 1, height: 12)
            Text(session.profile.destination).lineLimit(1).truncationMode(.middle)
            Rectangle().fill(WorkspaceAppearance.line).frame(width: 1, height: 12)
            Text(session.remoteDirectory?.path ?? "目录未上报").lineLimit(1).truncationMode(.head)
                .frame(maxWidth: 320, alignment: .leading)
                .help(session.remoteDirectory?.path ?? "等待远端的真实目录报告")
        }
    }
}
