import Foundation

public enum RemotePermissions {
    public static func parse(_ text: String) throws -> UInt32 {
        guard text.utf8.count == 3, text.utf8.allSatisfy({ (48...55).contains($0) }),
              let value = UInt32(text, radix: 8) else {
            throw SFTPError.message("权限请输入三位八进制数（000–777）。")
        }
        return value
    }

    public static func mode(original: UInt32, permissions: UInt32) throws -> UInt32 {
        guard permissions <= 0o777 else { throw SFTPError.message("只能修改普通读、写、执行权限（000–777）。") }
        return (original & 0o7000) | permissions
    }
}
