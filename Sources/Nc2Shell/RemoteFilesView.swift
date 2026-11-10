import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Nc2ShellCore

struct RemoteFilesView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: RemoteFilesModel
    @ObservedObject private var browser: RemoteBrowserState
    @ObservedObject private var navigation: RemoteNavigationState
    @ObservedObject private var bookmarks: RemoteDirectoryBookmarks
    @State private var pathInput = ""
    @State private var submittedPath: String?
    @FocusState private var pathFocused: Bool
    @FocusState private var filterFocused: Bool
    @State private var selection: Set<String> = []
    @State private var isDropTargeted = false
    @State private var bookmarkError: String?
    @State private var searchPresented = false
    @State private var permissionEdit: RemotePermissionEdit?
    @State private var showFilter = false
    private let close: () -> Void
    private let showTransfers: () -> Void

    init(session: TerminalSession, model: RemoteFilesModel, close: @escaping () -> Void = {}, showTransfers: @escaping () -> Void = {}) {
        self.close = close; self.showTransfers = showTransfers
        self.session = session; self.model = model; browser = model.browser
        navigation = model.navigation; bookmarks = session.directoryBookmarks
    }

    private var visibleFiles: [RemoteFile] { browser.visibleFiles(model.files) }
    private var selectedFiles: [RemoteFile] { browser.selectedFiles(model.files, selection: selection) }
    private var canTransfer: Bool { model.canManageFiles }
    private var hasPathDraft: Bool { pathInput != model.path }

    private var enqueueBlockedReason: String? {
        if !model.isConnected { return "请先连接服务器" }
        if model.isLoading { return "正在读取目录，请稍候" }
        if !model.locationValidated { return "等待当前目录确认后可操作" }
        if model.isManagingFiles { return "请等待当前文件操作结束" }
        if model.isPreparingUpload { return "正在读取拖入项目，请稍候" }
        return nil
    }

    private var downloadHelp: String {
        if let reason = enqueueBlockedReason { return reason }
        if selectedFiles.isEmpty { return "请先选择要下载的文件或文件夹" }
        if selectedFiles.contains(where: { $0.kind != .file && $0.kind != .directory }) {
            return "所选项目包含符号链接或特殊文件，无法下载"
        }
        return selectedFiles.count > 1 ? "下载所选 \(selectedFiles.count) 项…" : "下载所选项目…"
    }

    private var createDirectoryHelp: String {
        if let reason = enqueueBlockedReason { return reason }
        if !canTransfer {
            return model.isTransferring || model.transferItems.contains(where: { !$0.state.isFinished })
                ? "请先完成或取消当前传输，再新建文件夹" : "其他文件操作正在占用，请稍候"
        }
        return "新建文件夹"
    }

    private var followLabel: String {
        if !model.following { return "恢复跟随" }
        if model.followSuspension != nil { return "跟随已暂缓" }
        return model.reportedPath == nil ? "等待终端目录" : "正在跟随终端"
    }

    private var panelHeader: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("文件").font(.system(size: 18, weight: .regular))
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
                Button(action: browseParent) { Image(systemName: "arrow.up").font(.system(size: 14)) }
                    .buttonStyle(WorkspaceIconButton()).help("上级目录").accessibilityLabel("上级目录")
                    .disabled(!model.isConnected || !model.locationValidated || model.isLoading || model.isManagingFiles || model.path == "/")
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 14)) }
                    .buttonStyle(WorkspaceIconButton()).help("刷新目录").accessibilityLabel("刷新目录")
                    .disabled(!model.isConnected || model.isLoading || model.isManagingFiles)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 14)) }
                    .buttonStyle(WorkspaceIconButton()).help("收起文件面板").accessibilityLabel("收起文件面板")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    HStack(spacing: 2) {
                        TextField("远程路径", text: $pathInput).textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .regular)).onSubmit {
                                if !pathInput.isEmpty { submittedPath = pathInput; model.browse(pathInput) }
                            }
                            .focused($pathFocused)
                            .onExitCommand {
                                pathInput = model.path
                                submittedPath = nil
                                pathFocused = false
                                returnToTerminal()
                            }
                            .foregroundStyle(pathFocused ? WorkspaceAppearance.text : .clear)
                            .overlay {
                                if !pathFocused {
                                    // 只省略展示前缀，原生输入与提交始终保留完整路径。
                                    GeometryReader { geometry in
                                        Text(verbatim: pathInput.isEmpty ? "远程路径" : pathInput)
                                            .font(.system(size: 14, weight: .regular)).lineLimit(1).truncationMode(.head)
                                            .foregroundStyle(WorkspaceAppearance.text)
                                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                                    }.allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                            .disabled(!model.isConnected || model.isManagingFiles)
                            .accessibilityLabel(hasPathDraft ? "远程路径草稿，尚未前往" : "远程路径")
                            .help(hasPathDraft ? "草稿：\(pathInput)\n当前目录：\(model.path)\n回车前往，Esc 取消" : pathInput)
                        Menu { pathMenu } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(WorkspaceAppearance.secondary).help("目录导航与收藏")
                    }.padding(.horizontal, 10).frame(height: 40)
                        .background(WorkspaceAppearance.inputFill, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(hasPathDraft ? WorkspaceAppearance.accent.opacity(0.65) : WorkspaceAppearance.inputBorder))
                    Button { model.setFollowing(!model.following) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.following ? "link" : "link.badge.plus").font(.system(size: 17))
                            Text(!model.following ? "恢复跟随" : model.followSuspension != nil ? "跟随暂缓" : model.reportedPath == nil ? "等待目录" : "跟随终端")
                                .font(.system(size: 12, weight: .medium))
                        }.foregroundStyle(model.following ? WorkspaceAppearance.accent : WorkspaceAppearance.secondary)
                    }.buttonStyle(.plain).fixedSize().disabled(!model.isConnected)
                        .help(followLabel + "；点击暂停或恢复。只跟随远端实际报告的目录。")
                }
                if hasPathDraft {
                    Text("路径草稿 · 回车前往，Esc 取消")
                        .font(.system(size: 11)).foregroundStyle(WorkspaceAppearance.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                Button { upload() } label: { Image(systemName: "tray.and.arrow.up").font(.system(size: 17, weight: .light)) }
                    .disabled(!model.canEnqueue).help(enqueueBlockedReason ?? "上传文件或文件夹…").accessibilityLabel("上传")
                Button { download(selectedFiles) } label: { Image(systemName: "tray.and.arrow.down").font(.system(size: 17, weight: .light)) }
                    .disabled(!model.canDownload(selectedFiles))
                    .help(downloadHelp).accessibilityLabel("下载")
                Button { editName() } label: { Image(systemName: "folder.badge.plus") }
                    .help(createDirectoryHelp).accessibilityLabel("新建文件夹").disabled(!canTransfer)
                Spacer(minLength: 12)
                Button { showFilter.toggle() } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(showFilter || !browser.query.isEmpty ? WorkspaceAppearance.accent : WorkspaceAppearance.text)
                }.help(showFilter ? "收起筛选栏，保留筛选条件" : "筛选当前目录文件").accessibilityLabel("筛选文件")
                Menu { fileMenu } label: { Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 32, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(WorkspaceAppearance.text).tint(WorkspaceAppearance.text).help("更多文件操作")
            }.buttonStyle(WorkspaceIconButton())
            if showFilter {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(WorkspaceAppearance.secondary)
                    TextField("筛选当前目录", text: $browser.query).textFieldStyle(.plain)
                        .focused($filterFocused).onAppear {
                            // 输入框加入窗口后再请求焦点，否则原输入框会保留键盘输入。
                            DispatchQueue.main.async { if showFilter { filterFocused = true } }
                        }
                        .onExitCommand { browser.query = ""; showFilter = false }
                        .accessibilityLabel("筛选当前目录文件")
                    Button { browser.query = ""; showFilter = false } label: { Image(systemName: "xmark").font(.system(size: 13)) }
                        .buttonStyle(WorkspaceIconButton()).help("清除并关闭筛选（Esc）").accessibilityLabel("清除并关闭筛选")
                }.font(.system(size: 14)).padding(.leading, 10).padding(.trailing, 4).frame(height: 40)
                    .background(WorkspaceAppearance.inputFill, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(filterFocused ? WorkspaceAppearance.accent.opacity(0.65) : WorkspaceAppearance.inputBorder))
            } else if !browser.query.isEmpty {
                Button { showFilter = true } label: {
                    Text("筛选：\(browser.query)").lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).buttonStyle(.plain).foregroundStyle(WorkspaceAppearance.accent)
                    .help("筛选：\(browser.query)\n点击编辑或清除")
            }
            if model.following, let reason = model.followSuspension {
                Text("\(reason)\n文件面板仍属于 \(model.server)")
                    .font(.caption).foregroundStyle(WorkspaceAppearance.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
    }

    @ViewBuilder private var pathMenu: some View {
        Button("后退", action: model.goBack).disabled(!model.canGoBack)
        Button("前进", action: model.goForward).disabled(!model.canGoForward)
        Button("上级目录", action: browseParent)
            .disabled(!model.isConnected || !model.locationValidated || model.isLoading || model.isManagingFiles || model.path == "/")
        Divider()
        ForEach(RemoteNavigationState.breadcrumbs(for: model.path)) { part in
            Button { model.browse(part.path) } label: { Text(verbatim: part.path) }
                .disabled(!model.isConnected || model.isManagingFiles)
        }
        Divider()
        let currentPath = model.path
        Button(bookmarks.contains(currentPath, profile: session.profile) ? "取消收藏当前目录" : "收藏当前目录") {
            do { try bookmarks.toggle(currentPath, profile: session.profile); bookmarkError = nil }
            catch { bookmarkError = error.localizedDescription }
        }.disabled(!model.isConnected || !model.locationValidated || model.isLoading || bookmarks.readError != nil)
        let paths = bookmarks.paths(for: session.profile)
        ForEach(paths, id: \.self) { path in
            Button { model.browse(path) } label: { Label(path, systemImage: "star") }
                .disabled(!model.isConnected || model.isManagingFiles)
        }
    }

    private func browseParent() {
        let parent = (model.path as NSString).deletingLastPathComponent
        model.browse(parent.isEmpty ? "/" : parent)
    }

    @ViewBuilder private var fileMenu: some View {
        Button("刷新", action: model.refresh).disabled(!model.isConnected || model.isManagingFiles)
        Button("搜索当前目录及子目录…") { searchPresented = model.prepareSearch() }
            .disabled(!model.isConnected || !model.locationValidated || model.isLoading || model.isManagingFiles)
        Picker("排序", selection: $browser.sortField) {
            ForEach(RemoteBrowserState.SortField.allCases) { Text($0.title).tag($0) }
        }
        Toggle("升序", isOn: $browser.ascending)
        Toggle("显示隐藏文件", isOn: $browser.showHidden)
        Divider()
        Button("复制路径") { copyPaths(selectedFiles) }.disabled(selectedFiles.isEmpty)
        Button("属性…") { if let file = selectedFiles.first { properties(file) } }.disabled(selectedFiles.count != 1)
        Button("复制到…") { relocate(selectedFiles, copy: true) }.disabled(!model.canManage(selectedFiles))
        Button("移动到…") { relocate(selectedFiles, copy: false) }.disabled(!model.canManage(selectedFiles))
        Button("重命名…") { if let file = selectedFiles.first { editName(file) } }.disabled(selectedFiles.count != 1 || !model.canManage(selectedFiles))
        Button("删除…", role: .destructive) { delete(selectedFiles) }.disabled(!model.canManage(selectedFiles))
        Divider()
        Button("传输管理与待恢复任务", action: showTransfers)
        Button("取消所有正在传输的任务", action: model.cancelTransfer)
            .disabled(!model.isTransferring || model.isManagingFiles)
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Rectangle().fill(WorkspaceAppearance.line).frame(height: 1)
            HStack {
                sortHeader(.name)
                Spacer()
                sortHeader(.size).frame(width: 70, alignment: .trailing)
            }.font(.system(size: 14)).foregroundStyle(WorkspaceAppearance.secondary)
                .padding(.horizontal, 18).frame(height: 38)
            Rectangle().fill(WorkspaceAppearance.line).frame(height: 1)
            if !model.isConnected {
                ContentUnavailableView("连接后浏览文件", systemImage: "folder", description: Text("文件传输复用当前 SSH 登录。"))
            } else {
                RemoteFileTable(model: model, displayedFiles: visibleFiles, selection: $selection, isDropTargeted: $isDropTargeted,
                                download: download, createDirectory: { editName() }, rename: { editName($0) }, delete: delete,
                                properties: properties, copyPaths: copyPaths, relocate: { relocate($0, copy: $1) })
                .overlay { if visibleFiles.isEmpty && !model.isLoading && model.error == nil {
                    VStack(spacing: 10) {
                        Image(systemName: browser.query.isEmpty || model.files.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 24, weight: .light))
                        Text(model.files.isEmpty ? "此目录为空" : !browser.query.isEmpty ? "未找到匹配文件" : "当前目录仅有隐藏项目")
                            .font(.system(size: 14))
                        if !browser.query.isEmpty {
                            Button("清除筛选") { browser.query = "" }
                                .buttonStyle(.plain).foregroundStyle(WorkspaceAppearance.accent)
                        }
                    }.foregroundStyle(WorkspaceAppearance.secondary).padding(18)
                } }
            }
            panelFooter
        }
        .background(WorkspaceAppearance.panel)
        .overlay {
            if isDropTargeted && model.canEnqueue {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(WorkspaceAppearance.accent.opacity(0.12))
                    RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceAppearance.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.doc.fill").font(.largeTitle).foregroundStyle(WorkspaceAppearance.accent)
                        Text("松开即可上传").font(.headline)
                        Text(model.path).font(.caption).lineLimit(3).multilineTextAlignment(.center)
                    }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(24)
                }.padding(4).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], delegate: RemoteUploadDropDelegate(model: model, isTargeted: $isDropTargeted))
        .onAppear { pathInput = model.path }
        .onChange(of: model.path) { previous, path in
            if pathInput == previous { pathInput = path }
            selection = []
        }
        .onChange(of: model.isLoading) { _, loading in
            if !loading, let submittedPath {
                // 成功提交后显示规范路径；请求期间继续编辑的内容仍属于新草稿。
                if model.locationValidated, pathInput == submittedPath { pathInput = model.path }
                self.submittedPath = nil
            }
        }
        .onChange(of: model.files) { _, _ in selection = [] }
        .onChange(of: visibleFiles.map(\.name)) { _, names in selection.formIntersection(Set(names)) }
        .onChange(of: model.connectionID) { _, _ in
            searchPresented = false; submittedPath = nil; pathInput = model.path
        }
        .onChange(of: showFilter) { _, visible in
            if !visible {
                filterFocused = false
                returnToTerminal()
            }
        }
        .sheet(isPresented: $searchPresented) { RemoteSearchView(model: model.search, files: model) }
        .sheet(item: $permissionEdit) { RemotePermissionsView(model: model, edit: $0) }
    }

    private func sortHeader(_ field: RemoteBrowserState.SortField) -> some View {
        Button { browser.sortBy(field) } label: {
            HStack(spacing: 4) {
                Text(field.title)
                if browser.sortField == field {
                    Image(systemName: browser.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(WorkspaceAppearance.accent)
                }
            }.frame(height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(browser.sortField == field ? (browser.ascending ? "当前升序，点击降序排列" : "当前降序，点击升序排列") : "按\(field.title)升序排列")
            .accessibilityLabel("按\(field.title)排序")
    }

    private func returnToTerminal() {
        // 先让 SwiftUI 完成输入框失焦，避免随后把刚恢复的终端焦点清掉。
        DispatchQueue.main.async { session.terminal.window?.makeFirstResponder(session.terminal) }
    }

    private var panelFooter: some View {
        let activeItem = model.transferItems.first(where: { !$0.state.isFinished })
        // 只把对应活动任务的提示并入卡片，排队、并行任务与拖入准备仍独立显示。
        let compactSummary = activeItem.flatMap {
            $0.id == model.soleActiveTransferID && !model.isPreparingUpload && model.error == nil ? model.message : nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(6).help(error)
            } else if let message = model.message, compactSummary == nil {
                Text(message).font(.caption).foregroundStyle(WorkspaceAppearance.secondary).lineLimit(2).help(message)
            }
            if let error = bookmarkError ?? bookmarks.readError {
                Text("常用目录：\(error)").font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
            }
            if model.isManagingFiles {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("正在处理远程文件…").font(.caption)
                    Spacer()
                    Button("取消", action: model.cancelTransfer)
                }
            }
            if let item = activeItem {
                CompactTransferView(item: item, model: model, summary: compactSummary, showTransfers: showTransfers)
            }
            if activeItem == nil || !selection.isEmpty || !browser.query.isEmpty || visibleFiles.count != model.files.count {
            HStack {
                Text(selection.isEmpty ? (visibleFiles.count == model.files.count ? "\(visibleFiles.count) 项" : "显示 \(visibleFiles.count) / \(model.files.count) 项") : "已选 \(selection.count) 项")
                    .help("显示 \(visibleFiles.count) / \(model.files.count) 项 · ⌘/Shift 多选 · 拖入上传 · 拖到 Finder 下载")
                Spacer()
                Button(action: showTransfers) {
                    Label(model.transferItems.isEmpty ? "传输管理" : "传输管理 · \(model.transferItems.count)", systemImage: "arrow.up.arrow.down")
                }.buttonStyle(.plain).help("所有会话的传输任务与恢复记录")
            }.font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(WorkspaceAppearance.line).frame(height: 1) }
    }

    private func upload() {
        let directory = model.path, connectionID = model.connectionID, revision = model.locationRevision
        let panel = NSOpenPanel()
        panel.title = "上传到 \(model.path)"; panel.prompt = "上传"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { response in if response == .OK { model.upload(panel.urls, expectedPath: directory, connectionID: connectionID, revision: revision) } }
    }

    private func editName(_ file: RemoteFile? = nil) {
        guard canTransfer, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if let file, !model.canManage([file]) { return }
        let directory = model.path, connectionID = model.connectionID, revision = model.locationRevision
        let alert = NSAlert()
        alert.messageText = file == nil ? "新建远程文件夹" : "重命名"
        alert.informativeText = "服务器：\(session.profile.destination)\n目录：\(directory)\n请输入名称，同名不覆盖。"
        alert.addButton(withTitle: file == nil ? "新建" : "重命名")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = file?.name ?? ""; field.placeholderString = "文件夹名称"
        field.setAccessibilityLabel("名称")
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if let file { model.rename(file, to: field.stringValue, expectedPath: directory, connectionID: connectionID, revision: revision) }
            else { model.createDirectory(field.stringValue, expectedPath: directory, connectionID: connectionID, revision: revision) }
        }
        field.selectText(nil)
    }

    private func copyPaths(_ selected: [RemoteFile]) {
        guard !selected.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RemoteBrowserState.paths(selected, in: model.path), forType: .string)
    }

    private func properties(_ file: RemoteFile) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let edit = RemotePermissionEdit(file: file, directory: model.path, connectionID: model.connectionID,
                                        revision: model.locationRevision, server: "\(session.profile.destination):\(session.profile.port)")
        let alert = NSAlert()
        alert.messageText = "远程项目属性"
        let size = file.kind == .directory ? "未统计文件夹内容" : file.hasSize ? "\(file.size) 字节" : "未知"
        alert.informativeText = "名称：\(String(reflecting: file.name))\n类型：\(RemoteBrowserState.kind(file))\n大小：\(size)\n修改时间：\(RemoteBrowserState.modified(file))\n权限：\(RemoteBrowserState.permissions(file))\n\n服务器：\(session.profile.destination)\n路径：\(RemoteFile.join(model.path, file.name))"
        alert.addButton(withTitle: "知道了")
        if model.canManage([file]) { alert.addButton(withTitle: "修改权限…").keyEquivalent = "" }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { permissionEdit = edit }
        }
    }

    private func relocate(_ selected: [RemoteFile], copy: Bool) {
        guard model.canManage(selected), let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let directory = model.path, connectionID = model.connectionID, revision = model.locationRevision
        let alert = NSAlert()
        alert.messageText = "\(copy ? "复制" : "移动") \(selected.count) 项到远程目录"
        let names = selected.prefix(8).map { String(reflecting: $0.name) }.joined(separator: "\n")
        let more = selected.count > 8 ? "\n另有 \(selected.count - 8) 项" : ""
        let effect = copy ? "原文件保留。" : "已移动的项目会从来源目录移走；中途失败不会回滚已完成项。"
        alert.informativeText = "服务器：\(session.profile.destination)\n来源：\(directory)\n\n\(names)\(more)\n\n填写同一服务器上目标文件夹的绝对路径；同名时询问。\(effect)"
        alert.addButton(withTitle: "取消")
        let action = alert.addButton(withTitle: copy ? "复制" : "移动"); action.keyEquivalent = ""
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = directory; field.placeholderString = "目标远程目录"
        field.setAccessibilityLabel("目标远程目录")
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            model.relocate(selected, toDirectory: field.stringValue, copy: copy, expectedPath: directory, connectionID: connectionID, revision: revision)
        }
        field.selectText(nil)
    }

    private func delete(_ selected: [RemoteFile]) {
        guard model.canManage(selected), let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let directory = model.path, connectionID = model.connectionID, revision = model.locationRevision
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "永久删除 \(selected.count) 项？"
        let names = selected.prefix(8).map { String(reflecting: $0.name) }.joined(separator: "\n")
        let more = selected.count > 8 ? "\n另有 \(selected.count - 8) 项" : ""
        alert.informativeText = "服务器：\(session.profile.destination)\n目录：\(directory)\n\n\(names)\(more)\n\n文件夹及其全部内容将被永久删除，不进入废纸篓，无法撤销。"
        // 默认回车取消，只有明确点击永久删除才执行。
        alert.addButton(withTitle: "取消")
        let delete = alert.addButton(withTitle: "永久删除")
        delete.hasDestructiveAction = true; delete.keyEquivalent = ""
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { model.delete(selected, expectedPath: directory, connectionID: connectionID, revision: revision) }
        }
    }

    private func download(_ selected: [RemoteFile]) {
        guard model.canDownload(selected) else { return }
        let directory = model.path, connectionID = model.connectionID, revision = model.locationRevision
        if selected.count == 1, let file = selected.first {
            let panel = NSSavePanel()
            panel.title = "下载 \(file.name)"; panel.prompt = "下载"
            panel.nameFieldStringValue = file.name; panel.canCreateDirectories = true
            panel.begin { response in if response == .OK, let url = panel.url { model.download(file, to: url, expectedPath: directory, connectionID: connectionID, revision: revision) } }
        } else {
            let panel = NSOpenPanel()
            panel.title = "下载 \(selected.count) 项到本地目录"; panel.prompt = "下载"
            panel.message = "所选文件和文件夹将保留原名，遇到同名项目时询问处理方式。"
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
            panel.begin { response in if response == .OK, let url = panel.url { model.download(selected, into: url, expectedPath: directory, connectionID: connectionID, revision: revision) } }
        }
    }
}

@MainActor
private struct RemoteUploadDropDelegate: DropDelegate {
    let model: RemoteFilesModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool { model.canEnqueue && info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepts = validateDrop(info: info)
        isTargeted = accepts
        return DropProposal(operation: accepts ? .copy : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return model.uploadDroppedItems(info.itemProviders(for: [.fileURL]))
    }
}


struct CompactTransferView: View {
    @ObservedObject var item: TransferQueueItem
    @ObservedObject var model: RemoteFilesModel
    let summary: String?
    let showTransfers: () -> Void

    private var progress: (name: String, position: String)? {
        // 只拆分模型已知的进度格式，文件名内部的冒号和省略号必须原样保留。
        guard let summary, summary.hasSuffix("…"),
              let prefix = summary.range(of: "^正在(?:上传|下载|处理) [0-9]+/[0-9]+：", options: .regularExpression),
              let position = summary[prefix].dropLast().split(separator: " ").last else { return nil }
        return (String(summary[prefix.upperBound...].dropLast()), String(position))
    }

    var title: String { progress?.name ?? item.name }
    var subtitle: String { progress.map { "\(item.direction.rawValue) · \($0.position)" } ?? summary ?? item.direction.rawValue }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Button(action: showTransfers) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("\(title)\n\(subtitle)\n查看此任务及全部传输")
                if let fraction = item.fractionCompleted {
                    ProgressView(value: fraction).progressViewStyle(WorkspaceTransferProgressStyle()).frame(height: 6)
                        .accessibilityLabel("传输进度")
                } else {
                    Capsule().fill(WorkspaceAppearance.line).frame(height: 6)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Text(item.isEstimating ? "正在统计…" : "\(bytes(item.bytes))" + (item.estimatedTotalBytes.map { " / \(bytes($0))" } ?? " · 总量未知"))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 4)
                        Text(item.state == .paused ? "已暂停" : item.isWaitingForConflict ? "等待冲突处理" : item.state == .queued ? "排队中" : item.currentSpeed(at: context.date).map { "\(bytes(UInt64($0)))/s" } ?? "等待进展")
                            .lineLimit(1)
                    }.font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary).monospacedDigit()
                }
            }.frame(maxWidth: .infinity)
            HStack(spacing: 2) {
                if item.state == .paused {
                    Button { model.resumeTransfer(item.id) } label: { Image(systemName: "play.fill").font(.system(size: 15)) }
                        .help("继续传输").accessibilityLabel("继续传输")
                } else {
                    Button { model.pauseTransfer(item.id) } label: { Image(systemName: "pause.fill").font(.system(size: 15)) }
                        .help("暂停传输").accessibilityLabel("暂停传输")
                }
                Button { model.cancelQueuedTransfer(item.id) } label: { Image(systemName: "xmark").font(.system(size: 15)) }
                    .help("取消此任务").accessibilityLabel("取消此任务")
            }.buttonStyle(WorkspaceIconButton())
        }.padding(.vertical, 8)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

/// 自绘进度填充，避免 macOS 原生进度条在窗口失焦时把品牌色替换成灰色。
private struct WorkspaceTransferProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    Capsule().fill(WorkspaceAppearance.accent)
                        .frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
                }
        }
    }
}
