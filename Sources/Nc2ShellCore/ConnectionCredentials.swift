import Foundation
import Security

public protocol ConnectionCredentials {
    func password(for profile: ConnectionProfile) throws -> String?
    func setPassword(_ password: String?, for profile: ConnectionProfile) throws
}

public struct KeychainCredentials: ConnectionCredentials {
    public init() {}

    private func query(_ profile: ConnectionProfile) throws -> [String: Any] {
        // 名称可改；主机、端口或用户名变化必须成为另一凭据，不能静默借用旧密码。
        let account = try JSONEncoder().encode([profile.id.uuidString, profile.host, String(profile.port), profile.username]).base64EncodedString()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.nc2oding.Nc2Shell.password",
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false]
    }

    public func password(for profile: ConnectionProfile) throws -> String? {
        var query = try query(profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw ProfileError("钥匙串密码数据无效，请重新保存密码。")
        }
        return password
    }

    public func setPassword(_ password: String?, for profile: ConnectionProfile) throws {
        let query = try query(profile)
        guard let password else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        try Self.validate(password)
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Nc2Shell · \(profile.destination):\(profile.port)"
            try check(SecItemAdd(attributes as CFDictionary, nil))
        } else { try check(status) }
    }

    public static func validate(_ password: String) throws {
        guard !password.isEmpty, password.utf8.count <= 1022,
              !password.contains("\0"), !password.contains("\n"), !password.contains("\r") else {
            throw ProfileError("密码不能为空，不能包含换行或 NUL，且不能超过 1022 个 UTF-8 字节。")
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "系统错误 \(status)"
            throw ProfileError("钥匙串操作失败：\(detail)")
        }
    }
}
