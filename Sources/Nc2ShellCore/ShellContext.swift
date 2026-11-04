import Foundation

public struct ShellContext: Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let tty: String
    public let tmuxExecutable: String?

    public static func parse(report: String, token: String) -> ShellContext? {
        guard report.utf8.count < 8192,
              report.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              var components = URLComponents(string: report) else { return nil }
        let query = components.queryItems ?? []
        let tmux: String?
        if query.isEmpty { tmux = nil }
        else {
            guard query.count == 1, query[0].name == "tmux", let value = query[0].value,
                  value.hasPrefix("/"), value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            tmux = value
        }
        components.query = nil
        guard let plainReport = components.string, let directory = RemoteDirectory.parse(plainReport),
              directory.host == "context-" + token else { return nil }
        let fields = directory.path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3,
              fields[0].utf8.allSatisfy({ (48...57).contains($0) }),
              fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let pid = Int32(fields[0]), pid > 0, let uid = UInt32(fields[1]) else { return nil }
        let tty = "/" + fields[2]
        guard tty.range(of: #"\A/dev/(pts/[0-9]+|tty[0-9A-Za-z]+)\z"#, options: .regularExpression) != nil else { return nil }
        return ShellContext(pid: pid, uid: uid, tty: tty, tmuxExecutable: tmux)
    }
}
