import SwiftUI
import AppKit

struct WorkspaceFormHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 22, weight: .light))
                .foregroundStyle(WorkspaceAppearance.accent)
                .frame(width: 44, height: 44)
                .background(WorkspaceAppearance.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 21, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct WorkspaceFormSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .medium))
                .foregroundStyle(WorkspaceAppearance.text)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(WorkspaceAppearance.inputFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspaceAppearance.line, lineWidth: 1))
    }
}

struct WorkspaceFormFieldStyle: ViewModifier {
    var height: CGFloat = 36
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 13))
            .focused($focused).padding(.horizontal, 10).frame(height: height)
            .background(Color(nsColor: WorkspaceAppearance.terminal).opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? WorkspaceAppearance.accent : WorkspaceAppearance.inputBorder, lineWidth: 1))
    }
}

struct WorkspaceFormButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: primary ? .medium : .regular))
            .padding(.horizontal, 16).frame(height: 36)
            .foregroundStyle(primary ? Color(nsColor: WorkspaceAppearance.terminal) : WorkspaceAppearance.text)
            .background(primary ? WorkspaceAppearance.accent : WorkspaceAppearance.selected, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? Color.clear : WorkspaceAppearance.inputBorder, lineWidth: 1))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

struct WorkspaceFormToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

struct WorkspaceFormMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct WorkspaceFormChoiceStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity).frame(height: 30)
            .foregroundStyle(selected ? WorkspaceAppearance.accent : WorkspaceAppearance.secondary)
            .background(selected ? WorkspaceAppearance.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct WorkspaceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ObservedObject var transferSettings: TransferSettingsController
    @State private var page: WorkspaceSettingsDraft.Page = .terminal
    @State private var draft: WorkspaceSettingsDraft
    @State private var error: String?

    init(model: AppModel, transferSettings: TransferSettingsController) {
        self.model = model
        self.transferSettings = transferSettings
        _draft = State(initialValue: WorkspaceSettingsDraft(terminal: model.preferences, transfer: transferSettings.preferences))
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceFormHeader(title: "设置", subtitle: "终端、快捷键与传输偏好保存在这台 Mac 上。", icon: "gearshape")
                .padding(.horizontal, 20).padding(.vertical, 10)
            WorkspaceAppearance.line.frame(height: 1)
            HStack(spacing: 3) {
                ForEach(WorkspaceSettingsDraft.Page.allCases, id: \.self) { sectionButton($0) }
            }.padding(3)
                .background(Color(nsColor: WorkspaceAppearance.terminal).opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 20).padding(.top, 10)
            // 草稿归弹窗持有；切页只更换内容，隐藏页不会接收输入。
            switch page {
            case .terminal: TerminalSettingsView(draft: $draft.terminal)
            case .shortcuts: TerminalSettingsView(draft: $draft.terminal, showsShortcuts: true)
            case .transfers: TransferSettingsView(draft: $draft.transfer)
            }
            VStack(spacing: 8) {
                if let message = error ?? model.settingsError ?? transferSettings.error {
                    WorkspaceFormMessage(message: message)
                }
                HStack {
                    Button("恢复本页默认") { draft.reset(page); error = nil }
                        .buttonStyle(WorkspaceFormButtonStyle())
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(WorkspaceFormButtonStyle())
                    Button("保存", action: save).keyboardShortcut(.defaultAction)
                        .buttonStyle(WorkspaceFormButtonStyle(primary: true))
                        .disabled(model.settingsError != nil)
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
                .overlay(alignment: .top) { WorkspaceAppearance.line.frame(height: 1) }
        }.frame(width: 640).frame(minHeight: 540, idealHeight: 640, maxHeight: 720)
            .background(WorkspaceAppearance.panel).foregroundStyle(WorkspaceAppearance.text)
            .tint(WorkspaceAppearance.accent).environment(\.colorScheme, .dark)
    }

    private func save() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        do { _ = try draft.terminal.validated() }
        catch { page = .shortcuts; self.error = error.localizedDescription; return }
        do {
            let transfer = try draft.transfer.validated()
            try model.saveSettings(terminal: draft.terminal, transfer: transfer, controller: transferSettings)
            dismiss()
        } catch {
            if (try? draft.transfer.validated()) == nil { page = .transfers }
            self.error = "保存设置失败：\(error.localizedDescription)"
        }
    }

    private func sectionButton(_ destination: WorkspaceSettingsDraft.Page) -> some View {
        Button {
            NSApp.keyWindow?.makeFirstResponder(nil)
            page = destination
        } label: {
            Label(destination.rawValue, systemImage: destination.icon)
        }.buttonStyle(WorkspaceFormChoiceStyle(selected: page == destination))
            .accessibilityAddTraits(page == destination ? .isSelected : [])
    }
}
