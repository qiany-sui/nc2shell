import Foundation

public struct ConnectionProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var identityFile: String
    public var rememberPassword: Bool
    public var autoReconnect: Bool

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String = "", identityFile: String = "", rememberPassword: Bool = false, autoReconnect: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.rememberPassword = rememberPassword
        self.autoReconnect = autoReconnect
    }

    private enum CodingKeys: String, CodingKey { case id, name, host, port, username, identityFile, rememberPassword, autoReconnect }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        identityFile = try values.decode(String.self, forKey: .identityFile)
        rememberPassword = try values.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? false
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
    }

    public func hasSameCredentialAccount(as other: ConnectionProfile) -> Bool {
        id == other.id && host == other.host && port == other.port && username == other.username
    }

    public var destination: String { username.isEmpty ? host : "\(username)@\(host)" }

    public func validated() throws -> ConnectionProfile {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.host.hasPrefix("["), value.host.hasSuffix("]") {
            value.host = String(value.host.dropFirst().dropLast())
        }
        guard !value.name.isEmpty else { throw ProfileError("请填写连接名称。") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:%")
        guard !value.host.isEmpty, !value.host.hasPrefix("-"), value.host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ProfileError("主机请填写域名、IP 地址或 SSH 配置别名，不要包含用户名或命令。")
        }
        guard (1...65535).contains(port) else { throw ProfileError("端口必须在 1 到 65535 之间。") }
        guard value.username.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw ProfileError("用户名不能包含空格、换行或控制字符。")
        }
        guard !rememberPassword || !value.username.isEmpty else {
            throw ProfileError("记住密码时请明确填写用户名，避免 SSH 配置变化后使用错误账户。")
        }
        guard identityFile.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProfileError("私钥路径不能包含控制字符。")
        }
        return value
    }
}

public struct ProfileError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
