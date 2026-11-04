import SwiftUI
import Nc2ShellCore

@MainActor
final class TransferSettingsController: ObservableObject {
    static let shared = TransferSettingsController()
    @Published private(set) var preferences: TransferPreferences
    @Published var error: String?
    let limiter: TransferBandwidthLimiter
    let store: TransferPreferencesStore

    init(store: TransferPreferencesStore = .standard) {
        self.store = store
        var initial = TransferPreferences()
        var loadError: String?
        do { initial = try store.load() }
        catch { loadError = "读取传输设置失败，暂用默认值且不会覆盖原文件：\(error.localizedDescription)\n\(store.fileURL.path)" }
        preferences = initial
        limiter = TransferBandwidthLimiter(uploadBytesPerSecond: UInt64(initial.uploadLimitKiB) * 1024,
                                           downloadBytesPerSecond: UInt64(initial.downloadLimitKiB) * 1024)
        error = loadError
    }

    @discardableResult
    func save(_ value: TransferPreferences) -> Bool {
        do {
            let value = try value.validated()
            try store.save(value)
            applyPreferences(value)
            return true
        } catch {
            self.error = "保存传输设置失败：\(error.localizedDescription)\n\(store.fileURL.path)"
            return false
        }
    }

    func applyPreferences(_ value: TransferPreferences) {
        // 所有会话共享此实例，保存时更新额度并唤醒已有等待者。
        limiter.setLimits(uploadBytesPerSecond: UInt64(value.uploadLimitKiB) * 1024,
                          downloadBytesPerSecond: UInt64(value.downloadLimitKiB) * 1024)
        preferences = value
        error = nil
    }
}

struct TransferSettingsView: View {
    @Binding var draft: WorkspaceSettingsDraft.Transfer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    helpText("管理并行任务、带宽与文件属性。")
                    WorkspaceFormSection(title: "任务并行", icon: "square.stack.3d.up") {
                        HStack(spacing: 16) {
                            Text("每个会话同时传输").font(.system(size: 13))
                            HStack(spacing: 3) {
                                ForEach(1...4, id: \.self) { count in
                                    Button("\(count) 项") { draft.maxConcurrentTransfers = count }
                                        .buttonStyle(WorkspaceFormChoiceStyle(selected: draft.maxConcurrentTransfers == count))
                                        .accessibilityLabel("同时传输：\(count) 项")
                                        .accessibilityAddTraits(draft.maxConcurrentTransfers == count ? .isSelected : [])
                                }
                            }.padding(3).background(Color(nsColor: WorkspaceAppearance.terminal).opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                        }
                        helpText("每个任务可单独暂停和取消。降低并行数时，已开始的任务会继续，后续任务等待空位。")
                    }
                    WorkspaceFormSection(title: "全应用限速", icon: "speedometer") {
                        HStack(spacing: 24) {
                            bandwidthField("上传上限", icon: "arrow.up", value: $draft.uploadLimit, accessibility: "上传限速")
                            bandwidthField("下载上限", icon: "arrow.down", value: $draft.downloadLimit, accessibility: "下载限速")
                        }
                        helpText("0 表示不限速。可填 0–1048576 的整数，1 KiB = 1024 字节。上传和下载分别汇总所有会话的文件数据流量。")
                        helpText("保存后立即应用于现有及新建会话，并在下次启动保留。")
                    }
                    WorkspaceFormSection(title: "文件属性", icon: "doc.badge.gearshape") {
                        WorkspaceFormToggle(title: "保留修改时间（精确到秒）", isOn: $draft.attributes.preserveModificationTime)
                        WorkspaceFormToggle(title: "保留普通权限（读、写、执行）", isOn: $draft.attributes.preservePermissions)
                        helpText("仅影响新任务；排队与恢复任务保持原选项。合并时不改已有目录自身属性，跳过项保持原样。")
                        helpText("属性保存失败会停止本批并保留已传完的内容。若保留的权限使文件无法读取，恢复时需先自行检查权限。")
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }

    private func bandwidthField(_ title: String, icon: String, value: Binding<String>, accessibility: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
            TextField("不限速", text: value).modifier(WorkspaceFormFieldStyle()).frame(width: 108)
                .accessibilityLabel(accessibility)
            Text("KiB/s").font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
        }
    }

    private func helpText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
    }

}
