import Foundation

public struct RemoteDirectory: Equatable {
    public let host: String
    public let path: String

    public init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    public static func parse(_ report: String) -> RemoteDirectory? {
        guard report.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              let url = URLComponents(string: report), url.scheme == "file",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let path = url.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return RemoteDirectory(host: host, path: path)
    }
}
