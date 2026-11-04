import Foundation
import Nc2ShellCore

struct WorkspaceSettingsDraft {
    enum Page: String, CaseIterable {
        case terminal = "终端", shortcuts = "快捷键", transfers = "传输"
        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .shortcuts: return "keyboard"
            case .transfers: return "arrow.up.arrow.down"
            }
        }
    }

    struct Transfer {
        var maxConcurrentTransfers: Int
        var uploadLimit: String
        var downloadLimit: String
        var attributes: TransferAttributeOptions

        init(_ value: TransferPreferences) {
            maxConcurrentTransfers = value.maxConcurrentTransfers
            uploadLimit = String(value.uploadLimitKiB)
            downloadLimit = String(value.downloadLimitKiB)
            attributes = value.attributes
        }

        func validated() throws -> TransferPreferences {
            guard let upload = Int(uploadLimit.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let download = Int(downloadLimit.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ProfileError("上传和下载限速请填写整数；0 表示不限速。")
            }
            return try TransferPreferences(maxConcurrentTransfers: maxConcurrentTransfers,
                                           uploadLimitKiB: upload, downloadLimitKiB: download,
                                           attributes: attributes).validated()
        }
    }

    var terminal: TerminalPreferences
    var transfer: Transfer

    init(terminal: TerminalPreferences, transfer: TransferPreferences) {
        self.terminal = terminal
        self.transfer = Transfer(transfer)
    }

    mutating func reset(_ page: Page) {
        let defaults = TerminalPreferences()
        switch page {
        case .terminal:
            terminal.theme = defaults.theme
            terminal.fontSize = defaults.fontSize
            terminal.scrollbackLines = defaults.scrollbackLines
            terminal.optionAsMetaKey = defaults.optionAsMetaKey
        case .shortcuts: terminal.shortcuts = defaults.shortcuts
        case .transfers: transfer = Transfer(TransferPreferences())
        }
    }
}
