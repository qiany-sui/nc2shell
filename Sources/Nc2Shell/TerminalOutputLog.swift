import Foundation
import Nc2ShellCore

/// 只保存远端字节流的文本部分；它不是全屏程序的终端录像或命令审计。
final class TerminalOutputLog {
    private var handle: FileHandle?
    private var filter = TerminalLogFilter()

    convenience init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw ProfileError("请选择本机日志文件。") }
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw ProfileError("日志文件已存在，请选择新文件；不会覆盖原内容。") }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.init(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    init(handle: FileHandle) { self.handle = handle }

    func append(_ bytes: ArraySlice<UInt8>) throws {
        guard let handle else { throw ProfileError("会话日志已经停止。") }
        let data = filter.consume(bytes)
        if !data.isEmpty { try handle.write(contentsOf: data) }
    }

    func close() throws {
        guard let handle else { return }
        self.handle = nil
        // 不完整 UTF-8 后缀在结束时统一解码，跨读取块的完整中文不会被替换。
        let tail = filter.finish()
        defer { try? handle.close() }
        if !tail.isEmpty { try handle.write(contentsOf: tail) }
        try handle.synchronize()
    }

    deinit { try? handle?.close() }
}

private struct TerminalLogFilter {
    private enum State { case text, escape, escapeIntermediate, csi, string, stringEscape }
    private var state: State = .text
    private var stringAllowsBell = false
    private var utf8: [UInt8] = []
    private var remaining = 0

    mutating func consume(_ bytes: ArraySlice<UInt8>) -> Data {
        var output = Data()
        for byte in bytes {
            // CAN / SUB 在任意控制序列内都取消当前序列；之后的可见文本不能继续被吞掉。
            if byte == 0x18 || byte == 0x1a { state = .text; continue }
            switch state {
            case .text:
                if byte == 0x1b { state = .escape }
                else if byte >= 0x20 && byte != 0x7f || [0x09, 0x0a, 0x0d].contains(byte) { emit(byte, into: &output) }
            case .escape:
                switch byte {
                case 0x5b: state = .csi
                case 0x5d: stringAllowsBell = true; state = .string
                case 0x50, 0x58, 0x5e, 0x5f: stringAllowsBell = false; state = .string
                case 0x20...0x2f: state = .escapeIntermediate
                case 0x1b: break
                default: state = .text
                }
            case .escapeIntermediate:
                if byte >= 0x30 { state = .text }
            case .csi:
                if (0x40...0x7e).contains(byte) { state = .text }
                else if byte == 0x1b { state = .escape }
            case .string:
                if byte == 0x1b { state = .stringEscape }
                else if byte == 0x07 && stringAllowsBell { state = .text }
            case .stringEscape:
                if byte == 0x5c || byte == 0x07 && stringAllowsBell { state = .text }
                else if byte != 0x1b { state = .string }
            }
        }
        return output
    }

    private mutating func emit(_ byte: UInt8, into output: inout Data) {
        if remaining > 0 {
            if (0x80...0xbf).contains(byte) {
                utf8.append(byte)
                remaining -= 1
                if remaining == 0 { output.append(contentsOf: String(decoding: utf8, as: UTF8.self).utf8); utf8.removeAll(keepingCapacity: true) }
                return
            }
            output.append(contentsOf: String(decoding: utf8, as: UTF8.self).utf8)
            utf8.removeAll(keepingCapacity: true)
            remaining = 0
        }
        switch byte {
        case 0x00...0x7f: output.append(byte)
        case 0xc2...0xdf: utf8 = [byte]; remaining = 1
        case 0xe0...0xef: utf8 = [byte]; remaining = 2
        case 0xf0...0xf4: utf8 = [byte]; remaining = 3
        default: output.append(contentsOf: "\u{fffd}".utf8)
        }
    }

    mutating func finish() -> Data {
        defer { utf8.removeAll(); remaining = 0 }
        return Data(String(decoding: utf8, as: UTF8.self).utf8)
    }
}
