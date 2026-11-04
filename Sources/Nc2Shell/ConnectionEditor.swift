import SwiftUI
import AppKit
import Nc2ShellCore

enum ConnectionAuthenticationChoice: String, CaseIterable, Identifiable {
    case password, privateKey, sshDefaults
    var id: Self { self }
    var title: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "私钥"
        case .sshDefaults: return "SSH 默认配置"
        }
    }

    static func initial(profile: ConnectionProfile, hasTemporaryPassword: Bool) -> Self {
        if !profile.identityFile.isEmpty { return .privateKey }
        if profile.name.isEmpty || profile.rememberPassword || hasTemporaryPassword { return .password }
        return .sshDefaults
    }

    func submission(profile: ConnectionProfile, password: String) -> (profile: ConnectionProfile, password: String?, clearTemporaryPassword: Bool) {
        var result = profile
        if self != .privateKey { result.identityFile = "" }
        if self == .sshDefaults { result.rememberPassword = false }
        return (result, self == .sshDefaults || password.isEmpty ? nil : password, self == .sshDefaults)
    }
}

struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile
    @State private var port: String
    @State private var error: String?
    @State private var password = ""
    @State private var authentication: ConnectionAuthenticationChoice
    @State private var showBackupPassword: Bool
    @State private var confirmPasswordRemoval = false
    private let isNew: Bool
    private let hasExistingPassword: Bool
    let onSave: (ConnectionProfile, String?, Bool) -> Void

    init(profile: ConnectionProfile, hasTemporaryPassword: Bool = false, onSave: @escaping (ConnectionProfile, String?, Bool) -> Void) {
        _profile = State(initialValue: profile)
        _port = State(initialValue: String(profile.port))
        isNew = profile.name.isEmpty
        hasExistingPassword = profile.rememberPassword || hasTemporaryPassword
        _authentication = State(initialValue: .initial(profile: profile, hasTemporaryPassword: hasTemporaryPassword))
        _showBackupPassword = State(initialValue: profile.rememberPassword || hasTemporaryPassword)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceFormHeader(title: isNew ? "新建 SSH 连接" : "编辑连接",
                                subtitle: "连接信息保存在这台 Mac 上。", icon: "server.rack")
                .padding(.horizontal, 20).padding(.vertical, 10)
            WorkspaceAppearance.line.frame(height: 1)
            ScrollView {
                VStack(spacing: 8) {
                    card {
                        sectionTitle("连接信息", icon: "network")
                        HStack(spacing: 16) {
                            field("连接名称") {
                                TextField("名称", text: $profile.name, prompt: Text("例如：开发服务器"))
                            }.frame(width: 282)
                            field("用户名", labelWidth: 48) {
                                TextField("用户名", text: $profile.username, prompt: Text("留空使用 SSH 配置"))
                            }
                        }
                        HStack(spacing: 16) {
                            field("主机") {
                                TextField("主机", text: $profile.host, prompt: Text("域名、IP 或 SSH 别名"))
                            }
                            field("端口", labelWidth: 28) { TextField("端口", text: $port) }.frame(width: 100)
                        }
                    }
                    authenticationSection
                    card {
                        HStack(spacing: 12) {
                            sectionTitle("连接恢复", icon: "arrow.clockwise")
                            Spacer()
                            WorkspaceFormToggle(title: "异常断开后自动重连一次", isOn: $profile.autoReconnect)
                                .fixedSize()
                        }
                        helpText("登录后异常断开，3 秒后重试一次；不重放命令或自动续传。")
                        DisclosureGroup("恢复说明") {
                            VStack(alignment: .leading, spacing: 6) {
                                helpText("仅已登录的连接适用；等待 3 秒后尝试，可取消。每次手动连接最多一次，不重放命令或自动续传。需要输入口令或确认主机时请手动重连。")
                                if profile.autoReconnect {
                                    helpText("SSH 跳板、自定义代理或 Match 动态配置需要手动重连。自动恢复只保留旧终端文字，重置全屏与输入模式。")
                                    helpText("SSH 错误与远端 exit 255 使用相同退出码，无法区分；exit 255 也可能触发这一次重连。普通 exit 不触发。")
                                }
                            }.padding(.top, 6)
                        }.font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
            VStack(spacing: 8) {
                if let error { WorkspaceFormMessage(message: error) }
                HStack {
                    Label("仅保存配置，稍后连接", systemImage: "internaldrive")
                        .font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(WorkspaceFormButtonStyle())
                    Button("保存") { save() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(WorkspaceFormButtonStyle(primary: true))
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
                .overlay(alignment: .top) { WorkspaceAppearance.line.frame(height: 1) }
        }.frame(width: 600).frame(minHeight: 540, idealHeight: 640, maxHeight: 720).background(WorkspaceAppearance.panel)
            .foregroundStyle(WorkspaceAppearance.text).font(.system(size: 13))
            .tint(WorkspaceAppearance.accent).environment(\.colorScheme, .dark)
            .alert("改用 SSH 默认配置？", isPresented: $confirmPasswordRemoval) {
                Button("取消", role: .cancel) {}
                Button("移除已保存密码并保存", role: .destructive) { save(confirmedPasswordRemoval: true) }
            } message: {
                Text("将移除此连接在 App 中记住的账号密码，之后需要时重新输入。系统 SSH 配置和私钥文件不会被修改。")
            }
    }

    private var authenticationSection: some View {
        card {
            HStack {
                sectionTitle("身份验证", icon: "key.horizontal")
                Spacer(minLength: 12)
                HStack(spacing: 3) {
                    ForEach(ConnectionAuthenticationChoice.allCases) { choice in
                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            authentication = choice
                            error = nil
                        } label: {
                            Text(choice.title).font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .foregroundStyle(authentication == choice ? WorkspaceAppearance.accent : WorkspaceAppearance.secondary)
                                .background(authentication == choice ? WorkspaceAppearance.accent.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel("认证方式：\(choice.title)")
                            .accessibilityAddTraits(authentication == choice ? .isSelected : [])
                    }
                }.padding(3).frame(width: 366)
                    .background(Color(nsColor: WorkspaceAppearance.terminal).opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            }
            switch authentication {
            case .password:
                passwordFields
            case .privateKey:
                HStack(spacing: 10) {
                    field("私钥文件") {
                        TextField("私钥", text: $profile.identityFile, prompt: Text("留空使用系统默认密钥"))
                    }
                    Button("选择…", action: chooseKey).buttonStyle(WorkspaceFormButtonStyle())
                }
                helpText("私钥口令在连接时输入，与账号密码不同。")
                DisclosureGroup(isExpanded: $showBackupPassword) {
                    passwordFields.padding(.top, 8)
                } label: {
                    Text(hasExistingPassword || !password.isEmpty ? "备用账号密码 · 已配置" : profile.rememberPassword ? "备用账号密码 · 待填写" : "备用账号密码 · 可选")
                }.font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
            case .sshDefaults:
                helpText("使用系统 SSH 配置、默认密钥与密钥代理；需要密码或私钥口令时，在连接过程中输入。")
                helpText("保存后不使用本连接在 App 中指定的私钥或记住的账号密码。")
            }
        }
    }

    private var passwordFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                field("账号密码") {
                    SecureField("密码", text: $password, prompt: Text(hasExistingPassword ? "留空保留同账户已有密码" : "可选，留空在连接时输入"))
                }.frame(width: 354)
                WorkspaceFormToggle(title: "记住密码", isOn: $profile.rememberPassword)
                    .help("在此 Mac 的钥匙串中记住账号密码")
            }
            helpText(profile.rememberPassword ? "填写密码需明确用户名；密码存入此 Mac 的钥匙串，下次打开应用可用。" : "填写密码需明确用户名；未记住的密码仅在本次应用运行期间保留。")
            DisclosureGroup("密码认证说明") {
                helpText("填写密码时需明确用户名，仅自动尝试标准密码认证一次；多因素认证请使用“手动认证重新连接”。更改主机、端口或用户名后需重新输入密码。认证仍可使用系统 SSH 配置中的密钥。")
                    .padding(.top, 6)
            }.font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 14, weight: .medium))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(WorkspaceAppearance.inputFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspaceAppearance.line, lineWidth: 1))
    }

    private func field<Content: View>(_ title: String, labelWidth: CGFloat = 64, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content().modifier(WorkspaceFormFieldStyle()).accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func helpText(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
    }

    private func save(confirmedPasswordRemoval: Bool = false) {
        do {
            guard let value = Int(port) else { throw ProfileError("请输入有效端口。") }
            profile.port = value
            let submission = authentication.submission(profile: profile, password: password)
            let validated = try submission.profile.validated()
            if authentication == .sshDefaults, hasExistingPassword, !confirmedPasswordRemoval {
                confirmPasswordRemoval = true
                return
            }
            onSave(validated, submission.password, submission.clearTemporaryPassword)
        } catch { self.error = error.localizedDescription }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { profile.identityFile = url.path }
    }
}
