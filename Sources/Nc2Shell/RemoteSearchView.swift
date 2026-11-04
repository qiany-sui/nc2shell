import SwiftUI
import AppKit
import Nc2ShellCore

struct RemoteSearchView: View {
    @ObservedObject var model: RemoteSearchModel
    @ObservedObject var files: RemoteFilesModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @FocusState private var queryFocused: Bool

    private var selected: RemoteSearchMatch? { model.snapshot.matches.first { $0.path == selection } }
    private var canOpen: Bool { model.isConnected && files.isConnected && !files.isManagingFiles && model.connectionID == files.connectionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索远程文件").font(.title2.bold())
            Text("范围：" + model.directory).font(.caption).textSelection(.enabled).lineLimit(2).help(model.directory)
            HStack {
                TextField("文件名包含…", text: $model.query).textFieldStyle(.roundedBorder)
                    .focused($queryFocused).onSubmit { model.start() }.disabled(model.isRunning)
                Toggle("包含隐藏项目", isOn: $model.includeHidden).disabled(model.isRunning)
                if model.isRunning { Button("停止", action: model.cancel) }
                else { Button("搜索", action: model.start).disabled(!model.isConnected || model.directory.isEmpty || model.query.isEmpty) }
            }
            Text("包含子目录 · 不区分大小写 · 不跟随符号链接 · 最多 1,000 条结果").font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(model.snapshot.matches) { result in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: result.file.kind == .directory ? "folder" : result.file.kind == .symbolicLink ? "link" : "doc")
                            .frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: result.file.name).lineLimit(1)
                            Text(verbatim: result.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(result.path)
                        }
                        Spacer()
                        Text(RemoteBrowserState.kind(result.file)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(result.path)
                        .contextMenu {
                            Button("打开所在目录") { open(result) }.disabled(!canOpen)
                            Button("复制路径") { copy(result) }
                        }
                        .onTapGesture(count: 2) { open(result) }
                }
            }.overlay {
                if model.snapshot.matches.isEmpty {
                    Text(model.isRunning ? "正在查找…" : "暂无结果").foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }.border(Color(nsColor: .separatorColor))
            HStack {
                if model.isRunning { ProgressView().controlSize(.small) }
                Text("已检查 \(model.snapshot.scannedCount) 项 · 找到 \(model.snapshot.matches.count) 项 · 跳过 \(model.snapshot.skippedCount) 个目录")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.isRunning {
                Text(verbatim: model.snapshot.currentDirectory).font(.caption).lineLimit(1).help(model.snapshot.currentDirectory)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3).help(error) }
            if !model.snapshot.issues.isEmpty {
                DisclosureGroup("未能搜索的目录（显示前 \(model.snapshot.issues.count) 个）") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.snapshot.issues.indices, id: \.self) { index in
                                let issue = model.snapshot.issues[index]
                                Text(issue.path + "：" + issue.reason).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 80)
                }.font(.caption)
            }
            Divider()
            HStack {
                Button("打开所在目录") { if let selected { open(selected) } }.disabled(selected == nil || !canOpen)
                Button("复制路径") { if let selected { copy(selected) } }.disabled(selected == nil)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 740, height: 560)
            .onAppear { queryFocused = true }
            .onDisappear { model.cancel() }
            .onChange(of: model.snapshot.matches.isEmpty) { _, empty in if empty { selection = nil } }
    }

    private func open(_ result: RemoteSearchMatch) {
        if files.openSearchResult(result) { dismiss() }
    }

    private func copy(_ result: RemoteSearchMatch) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.path, forType: .string)
    }
}
