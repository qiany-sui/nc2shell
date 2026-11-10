import AppKit
import SwiftUI
import Nc2ShellCore
import SwiftTerm

enum TerminalTheme: String, Codable, CaseIterable, Identifiable {
    case midnight, light, solarized
    var id: Self { self }
    var title: String {
        switch self { case .midnight: return "深夜"; case .light: return "明亮"; case .solarized: return "Solarized 深色" }
    }
    var background: NSColor {
        switch self {
        case .midnight: return WorkspaceAppearance.terminal
        case .light: return NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
        case .solarized: return NSColor(srgbRed: 0, green: 0.169, blue: 0.212, alpha: 1)
        }
    }
    var foreground: NSColor {
        switch self {
        case .midnight: return NSColor(srgbRed: 234 / 255, green: 232 / 255, blue: 228 / 255, alpha: 1)
        case .light: return NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        case .solarized: return NSColor(srgbRed: 0.514, green: 0.58, blue: 0.588, alpha: 1)
        }
    }
    var caret: NSColor { self == .midnight ? WorkspaceAppearance.orange : self == .light ? .systemBlue : .systemTeal }
    var ansiColors: [SwiftTerm.Color] {
        var colors = SwiftTerm.Color.terminalAppColors
        if self == .midnight {
            colors[4] = SwiftTerm.Color(red8: 122, green8: 183, blue8: 255)
            colors[12] = SwiftTerm.Color(red8: 166, green8: 206, blue8: 255)
        }
        return colors
    }
}

enum TerminalAction: String, Codable, CaseIterable, Identifiable {
    case newConnection, connect, splitColumns, splitRows, nextPane, find, findNext, findPrevious
    case increaseFont, decreaseFont, resetFont, toggleLog, closePane
    var id: Self { self }
    var title: String {
        switch self {
        case .newConnection: return "新建 SSH 连接"
        case .connect: return "连接所选服务器"
        case .splitColumns: return "左右分屏"
        case .splitRows: return "上下分屏"
        case .nextPane: return "切换焦点窗格"
        case .find: return "查找终端内容…"
        case .findNext: return "查找下一项"
        case .findPrevious: return "查找上一项"
        case .increaseFont: return "放大字体"
        case .decreaseFont: return "缩小字体"
        case .resetFont: return "恢复默认字体"
        case .toggleLog: return "开始 / 停止会话日志…"
        case .closePane: return "关闭当前窗格"
        }
    }
    var defaultShortcut: AppShortcut {
        switch self {
        case .newConnection: return AppShortcut(key: "n")
        case .connect: return AppShortcut(key: "return")
        case .splitColumns: return AppShortcut(key: "d")
        case .splitRows: return AppShortcut(key: "d", shift: true)
        case .nextPane: return AppShortcut(key: "]", option: true)
        case .find: return AppShortcut(key: "f")
        case .findNext: return AppShortcut(key: "g")
        case .findPrevious: return AppShortcut(key: "g", shift: true)
        case .increaseFont: return AppShortcut(key: "=")
        case .decreaseFont: return AppShortcut(key: "-")
        case .resetFont: return AppShortcut(key: "0")
        case .toggleLog: return AppShortcut(key: "l", shift: true)
        case .closePane: return AppShortcut(key: "w", shift: true)
        }
    }
}

struct AppShortcut: Codable, Equatable, Hashable {
    var key: String
    var command = true
    var shift = false
    var option = false
    var control = false

    var modifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }
        if shift { result.insert(.shift) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        return result
    }
    var keyEquivalent: KeyEquivalent { key == "return" ? .return : KeyEquivalent(key.first ?? " ") }

    func validated() throws -> AppShortcut {
        var result = self
        result.key = key.lowercased()
        let shiftedKeys = ["~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/"]
        if let base = shiftedKeys[result.key] { result.key = base; result.shift = true }
        let characters = Array(result.key.unicodeScalars)
        guard command, result.key == "return" || (characters.count == 1 && characters[0].isASCII && characters[0].value > 32 && characters[0].value < 127) else {
            throw ProfileError("快捷键必须包含 ⌘，按键使用一个英文字母、数字、标点或 return；普通 Ctrl 组合留给远端。")
        }
        // 基本编辑、系统窗口与退出组合由 macOS 保留，不能被应用命令覆盖。
        let basic = ["c", "v", "x", "a", "z", "q", "h", "m", "w", ",", "`", " "]
        if (!result.shift && !result.option && !result.control && basic.contains(result.key)) || result.key == "q" ||
            (result.key == "z" && result.shift && !result.option && !result.control) ||
            (result.key == "v" && result.shift && result.option && !result.control) ||
            (result.key == "h" && result.option && !result.shift && !result.control) ||
            (result.key == "f" && result.control && !result.shift && !result.option) {
            throw ProfileError("该快捷键由系统编辑、窗口或退出操作保留，请换一个组合。")
        }
        return result
    }
}

struct TerminalPreferences: Codable, Equatable {
    static let scrollbackChoices = [5_000, 10_000, 50_000]
    var theme: TerminalTheme = .midnight
    var fontSize: Double = 16
    var scrollbackLines: Int = 10_000
    var optionAsMetaKey = true
    var shortcuts: [TerminalAction: AppShortcut] = Dictionary(uniqueKeysWithValues: TerminalAction.allCases.map { ($0, $0.defaultShortcut) })

    private enum CodingKeys: String, CodingKey {
        case theme, fontSize, scrollbackLines, optionAsMetaKey, shortcuts
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decode(TerminalTheme.self, forKey: .theme)
        fontSize = try values.decode(Double.self, forKey: .fontSize)
        shortcuts = try values.decode([TerminalAction: AppShortcut].self, forKey: .shortcuts)
        // 旧文件只缺新增字段时使用原行为；显式空值或错误类型仍视为损坏配置。
        if values.contains(.scrollbackLines) { scrollbackLines = try values.decode(Int.self, forKey: .scrollbackLines) }
        if values.contains(.optionAsMetaKey) { optionAsMetaKey = try values.decode(Bool.self, forKey: .optionAsMetaKey) }
    }

    func validated() throws -> TerminalPreferences {
        guard fontSize.isFinite, (10...28).contains(fontSize) else { throw ProfileError("默认字号需要在 10–28 之间。") }
        guard Self.scrollbackChoices.contains(scrollbackLines) else { throw ProfileError("回滚历史行数请选择 5,000、10,000 或 50,000 行。") }
        guard shortcuts.count == TerminalAction.allCases.count else { throw ProfileError("快捷键配置不完整，请检查设置文件。") }
        var result = self, used: Set<AppShortcut> = []
        for action in TerminalAction.allCases {
            guard let shortcut = shortcuts[action] else { throw ProfileError("缺少“\(action.title)”快捷键。") }
            let normalized = try shortcut.validated()
            guard used.insert(normalized).inserted else { throw ProfileError("“\(action.title)”与其他操作使用了相同快捷键。") }
            result.shortcuts[action] = normalized
        }
        return result
    }
}

struct TerminalSettingsStore {
    let fileURL: URL
    static var standard: Self {
        Self(fileURL: ConnectionStore.standard.fileURL.deletingLastPathComponent().appendingPathComponent("terminal-settings.json"))
    }
    func load() throws -> TerminalPreferences {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return TerminalPreferences() }
        return try JSONDecoder().decode(TerminalPreferences.self, from: data).validated()
    }
    func save(_ preferences: TerminalPreferences) throws {
        _ = try load()
        let value = try preferences.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

struct TerminalSettingsView: View {
    @Binding var draft: TerminalPreferences
    var showsShortcuts = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if showsShortcuts {
                        Text("必须包含 ⌘；普通 Ctrl 组合仍传给远端。按键支持字母、数字、标点或 return。")
                            .font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 0) {
                            ForEach(TerminalAction.allCases) { action in
                                ShortcutRow(action: action, shortcut: Binding(get: { draft.shortcuts[action] ?? action.defaultShortcut }, set: { draft.shortcuts[action] = $0 }))
                                if action != TerminalAction.allCases.last { WorkspaceAppearance.line.frame(height: 1) }
                            }
                        }.padding(10)
                            .background(WorkspaceAppearance.inputFill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkspaceAppearance.line, lineWidth: 1))
                    } else {
                        appearanceSection
                        behaviorSection
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }

    private var appearanceSection: some View {
        WorkspaceFormSection(title: "终端外观", icon: "paintpalette") {
            HStack(spacing: 10) {
                ForEach(TerminalTheme.allCases) { theme in
                    Button { draft.theme = theme } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                Text("❯").foregroundStyle(Color(nsColor: theme.caret))
                                Text("ssh server").foregroundStyle(Color(nsColor: theme.foreground))
                                Spacer(minLength: 0)
                            }.font(.system(size: 12, design: .monospaced))
                                .padding(10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                .background(Color(nsColor: theme.background), in: RoundedRectangle(cornerRadius: 5))
                            HStack {
                                Text(theme.title).font(.system(size: 12))
                                Spacer(minLength: 0)
                                Image(systemName: draft.theme == theme ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(draft.theme == theme ? WorkspaceAppearance.accent : WorkspaceAppearance.secondary)
                            }
                        }.padding(8).frame(maxWidth: .infinity)
                            .background(draft.theme == theme ? WorkspaceAppearance.accent.opacity(0.05) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(draft.theme == theme ? WorkspaceAppearance.accent : WorkspaceAppearance.inputBorder, lineWidth: 1))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(theme.title)
                        .accessibilityAddTraits(draft.theme == theme ? .isSelected : [])
                }
            }
            HStack(spacing: 16) {
                Text("默认字号").foregroundStyle(WorkspaceAppearance.secondary).frame(width: 96, alignment: .leading)
                HStack(spacing: 0) {
                    Button { draft.fontSize = max(10, draft.fontSize - 1) } label: { Image(systemName: "minus").frame(width: 36, height: 34) }
                        .disabled(draft.fontSize <= 10).accessibilityLabel("减小默认字号")
                    Text("\(Int(draft.fontSize)) pt").monospacedDigit().frame(width: 56).accessibilityLabel("默认字号")
                        .accessibilityValue("\(Int(draft.fontSize)) 点")
                    Button { draft.fontSize = min(28, draft.fontSize + 1) } label: { Image(systemName: "plus").frame(width: 36, height: 34) }
                        .disabled(draft.fontSize >= 28).accessibilityLabel("增大默认字号")
                }.buttonStyle(.plain)
                    .background(Color(nsColor: WorkspaceAppearance.terminal).opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkspaceAppearance.inputBorder, lineWidth: 1))
                Spacer()
                Text("10–28 pt").foregroundStyle(WorkspaceAppearance.secondary)
            }.font(.system(size: 13)).padding(.vertical, 4)
            Text("保存后应用于所有现有会话及新会话。每个标签支持两个独立终端，可切换上下或左右布局。")
                .font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviorSection: some View {
        WorkspaceFormSection(title: "终端行为", icon: "slider.horizontal.3") {
            HStack(spacing: 16) {
                Text("回滚历史行数").foregroundStyle(WorkspaceAppearance.secondary).frame(width: 96, alignment: .leading)
                HStack(spacing: 3) {
                    ForEach(TerminalPreferences.scrollbackChoices, id: \.self) { lines in
                        Button("\(lines.formatted()) 行") { draft.scrollbackLines = lines }
                            .buttonStyle(WorkspaceFormChoiceStyle(selected: draft.scrollbackLines == lines))
                            .accessibilityLabel("回滚历史：\(lines) 行")
                            .accessibilityAddTraits(draft.scrollbackLines == lines ? .isSelected : [])
                    }
                }.padding(3).background(Color(nsColor: WorkspaceAppearance.terminal).opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            }.font(.system(size: 13))
            Text("每个终端可向上查看的历史输出。行数越多越占内存；降低上限会移除较早的输出。全屏程序中调整会在返回普通终端后生效。")
                .font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WorkspaceAppearance.line.frame(height: 1).padding(.vertical, 4)
            HStack(spacing: 16) {
                Text("Option 键行为").foregroundStyle(WorkspaceAppearance.secondary).frame(width: 96, alignment: .leading)
                HStack(spacing: 3) {
                    Button("Alt / Meta") { draft.optionAsMetaKey = true }
                        .buttonStyle(WorkspaceFormChoiceStyle(selected: draft.optionAsMetaKey))
                        .accessibilityAddTraits(draft.optionAsMetaKey ? .isSelected : [])
                    Button("macOS 字符输入") { draft.optionAsMetaKey = false }
                        .buttonStyle(WorkspaceFormChoiceStyle(selected: !draft.optionAsMetaKey))
                        .accessibilityAddTraits(!draft.optionAsMetaKey ? .isSelected : [])
                }.padding(3).background(Color(nsColor: WorkspaceAppearance.terminal).opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            }.font(.system(size: 13))
            Text("Alt / Meta 用于远端 Shell 或编辑器组合键；字符输入沿用 macOS 键盘布局。")
                .font(.system(size: 12)).foregroundStyle(WorkspaceAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

private struct ShortcutRow: View {
    let action: TerminalAction
    @Binding var shortcut: AppShortcut

    var body: some View {
        HStack(spacing: 8) {
            Text(action.title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            Text("⌘").font(.system(size: 15)).foregroundStyle(WorkspaceAppearance.secondary).frame(width: 20)
                .help("所有应用快捷键都包含 Command")
            Toggle("⇧", isOn: $shortcut.shift).accessibilityLabel("\(action.title) Shift")
            Toggle("⌥", isOn: $shortcut.option).accessibilityLabel("\(action.title) Option")
            Toggle("⌃", isOn: $shortcut.control).accessibilityLabel("\(action.title) Control")
            TextField("按键", text: $shortcut.key).modifier(WorkspaceFormFieldStyle(height: 28)).frame(width: 72)
                .accessibilityLabel("\(action.title)按键")
        }.toggleStyle(ShortcutModifierStyle()).padding(.vertical, 1)
    }
}

private struct ShortcutModifierStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.font(.system(size: 15))
                .frame(width: 28, height: 26)
                .foregroundStyle(configuration.isOn ? WorkspaceAppearance.accent : WorkspaceAppearance.secondary)
                .background(configuration.isOn ? WorkspaceAppearance.accent.opacity(0.12) : WorkspaceAppearance.inputFill,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(configuration.isOn ? WorkspaceAppearance.accent.opacity(0.5) : WorkspaceAppearance.inputBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "已启用" : "未启用")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
