import Foundation

struct SFTPWriter {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func uint64(_ value: UInt64) { uint32(UInt32(value >> 32)); uint32(UInt32(truncatingIfNeeded: value)) }
    mutating func string(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
    mutating func text(_ value: String) { string(Data(value.utf8)) }
}

struct SFTPReader {
    let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw SFTPError.message("SFTP 响应不完整。") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { let high = try uint32(); return (UInt64(high) << 32) | UInt64(try uint32()) }
    mutating func string() throws -> Data { let count = try uint32(); return try bytes(Int(count)) }
    mutating func text() throws -> String {
        guard let text = String(data: try string(), encoding: .utf8) else { throw SFTPError.message("服务器返回了非 UTF-8 文件名。") }
        return text
    }
    mutating func attributes() throws -> (size: UInt64, mode: UInt32, modifiedTime: UInt32?, hasSize: Bool, accessedTime: UInt32?) {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPError.message("不支持的 SFTP 文件属性。") }
        let size = flags & 1 != 0 ? try uint64() : 0
        if flags & 2 != 0 { _ = try bytes(8) }
        let mode = flags & 4 != 0 ? try uint32() : 0
        var modifiedTime: UInt32?, accessedTime: UInt32?
        if flags & 8 != 0 { accessedTime = try uint32(); modifiedTime = try uint32() }
        if flags & 0x80000000 != 0 {
            let count = try uint32()
            guard count <= 1024 else { throw SFTPError.message("SFTP 扩展属性过多。") }
            for _ in 0..<count { _ = try string(); _ = try string() }
        }
        return (size, mode, modifiedTime, flags & 1 != 0, accessedTime)
    }
}

public enum SFTPError: LocalizedError {
    case message(String)
    case status(UInt32, String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .status(let code, let text):
            let reason = [UInt32(2): "路径不存在", 3: "没有访问权限", 4: "操作失败（目标可能已存在）", 8: "服务器不支持此操作"][code] ?? "操作失败"
            return "\(reason)：\(text)"
        }
    }
}

public struct RemoteFile: Identifiable, Equatable {
    public enum Kind { case file, directory, symbolicLink, other }
    public let name: String
    public let size: UInt64
    public let hasSize: Bool
    public let mode: UInt32
    // v3 只提供秒级 mtime；服务器未返回时间时保留 nil，不能假定为零。
    public let modifiedTime: UInt32?
    public var id: String { name }
    public var kind: Kind {
        switch mode & 0o170000 {
        case 0o100000: return .file
        case 0o040000: return .directory
        case 0o120000: return .symbolicLink
        default: return .other
        }
    }
    public init(name: String, size: UInt64, mode: UInt32, modifiedTime: UInt32? = nil, hasSize: Bool = true) {
        self.name = name; self.size = size; self.mode = mode; self.modifiedTime = modifiedTime; self.hasSize = hasSize
    }
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SFTPError.message("名称不能为空，不能是 . 或 ..，也不能包含 / 或空字符。")
        }
    }
    public static func join(_ directory: String, _ name: String) -> String { directory == "/" ? "/" + name : directory + "/" + name }
}
