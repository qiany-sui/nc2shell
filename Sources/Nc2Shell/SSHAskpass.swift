import Foundation
import Darwin
import Security
import Nc2ShellCore
import Nc2ShellAuthSupport

enum SSHAskpass {
    static let environmentKey = "NC2SHELL_ASKPASS_SOCKET"

    static func isAccountPasswordPrompt(_ prompt: String, username: String) -> Bool {
        let prefix = username + "@", suffix = "'s password: "
        guard !username.isEmpty, prompt.hasPrefix(prefix), prompt.hasSuffix(suffix),
              prompt.count > prefix.count + suffix.count,
              prompt.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return true
    }

    static func runIfRequested() -> Never? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        guard CommandLine.arguments.count == 2 else { exit(1) }
        let socket = nc2_auth_socket(path, 0)
        guard socket >= 0 else { exit(1) }
        let prompt = CommandLine.arguments[1]
        guard write(Data(prompt.utf8), to: socket), let response = read(from: socket), let kind = response.first else { exit(1) }
        close(socket)
        switch kind {
        case 1:
            FileHandle.standardOutput.write(response.dropFirst())
            FileHandle.standardOutput.write(Data([10]))
            exit(0)
        case 2:
            // SSH 只把 helper stdout 接到认证管道。其余提示通过控制终端读取，绝不猜终端输出。
            guard let password = nc2_auth_read_tty(prompt) else { exit(1) }
            let length = strlen(password)
            _ = nc2_auth_write(STDOUT_FILENO, password, length)
            nc2_auth_free_password(password)
            FileHandle.standardOutput.write(Data([10]))
            exit(0)
        default:
            FileHandle.standardError.write(response.dropFirst())
            exit(1)
        }
    }

    static func write(_ data: Data, to socket: Int32) -> Bool {
        guard data.count <= 16_384 else { return false }
        var count = UInt32(data.count).bigEndian
        guard nc2_auth_write(socket, &count, 4) != 0 else { return false }
        return data.withUnsafeBytes { nc2_auth_write(socket, $0.baseAddress, data.count) != 0 }
    }

    static func read(from socket: Int32) -> Data? {
        var count: UInt32 = 0
        guard nc2_auth_read(socket, &count, 4) != 0 else { return nil }
        let size = Int(UInt32(bigEndian: count))
        guard size <= 16_384 else { return nil }
        var data = Data(count: size)
        let valid = data.withUnsafeMutableBytes { nc2_auth_read(socket, $0.baseAddress, size) != 0 }
        return valid ? data : nil
    }
}

final class SSHPasswordBroker {
    let socketPath: String
    private let listener: Int32
    private let profile: ConnectionProfile
    private let credentials: ConnectionCredentials
    private let password: String?
    private let allowsInteractivePrompts: Bool
    private let executable: String
    private let executableHash: Data
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var sshPID: pid_t = 0
    private var stopped = false
    private var active: Int32 = -1
    private var passwordUsed = false

    init(directory: URL, profile: ConnectionProfile, executable: URL,
         credentials: ConnectionCredentials = KeychainCredentials(), password: String? = nil, allowsInteractivePrompts: Bool = true) throws {
        socketPath = directory.appendingPathComponent("a").path
        self.profile = profile
        self.credentials = credentials
        self.password = password
        self.allowsInteractivePrompts = allowsInteractivePrompts
        self.executable = executable.resolvingSymlinksInPath().path
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code, let hash = Self.codeHash(code) else {
            throw ProfileError("无法验证密码助手签名，请重新构建应用或使用手动认证。")
        }
        executableHash = hash
        listener = nc2_auth_socket(socketPath, 1)
        guard listener >= 0 else { throw ProfileError("无法建立本机安全密码通道，请使用手动认证。") }
    }

    func start(sshPID: pid_t) {
        lock.lock(); self.sshPID = sshPID; lock.unlock()
        ready.signal()
        DispatchQueue.global(qos: .userInitiated).async { [self] in serve() }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        shutdown(listener, SHUT_RDWR)
        close(listener)
        if active >= 0 { shutdown(active, SHUT_RDWR) }
        lock.unlock()
        unlink(socketPath)
    }

    private func serve() {
        ready.wait()
        while true {
            lock.lock(); let ended = stopped; lock.unlock()
            if ended { break }
            let socket = nc2_auth_accept(listener)
            if socket < 0 { break }
            lock.lock()
            if stopped { lock.unlock(); close(socket); break }
            active = socket
            let pid = sshPID
            lock.unlock()
            // 内核给出的 peer PID、真实可执行路径和直接父 PID 必须同时匹配当前 SSH。
            // 代理跳板、任意直接运行 helper、伪造环境都不能读取此会话密码。
            let helperPID = nc2_auth_peer_is_helper(socket, pid, executable)
            if helperPID > 0, helperHasExpectedSignature(helperPID),
               let request = SSHAskpass.read(from: socket), let prompt = String(data: request, encoding: .utf8) {
                let response: Data
                if SSHAskpass.isAccountPasswordPrompt(prompt, username: profile.username) {
                    if passwordUsed { response = Data([0]) }
                    else {
                        passwordUsed = true
                        do {
                            guard let password = try password ?? credentials.password(for: profile) else {
                                throw ProfileError("未找到已保存的密码；请编辑连接重新保存，或使用手动认证重连。")
                            }
                            try KeychainCredentials.validate(password)
                            response = Data([1]) + Data(password.utf8)
                        } catch { response = Data([0]) + Data((error.localizedDescription + "\n").utf8) }
                    }
                } else {
                    response = allowsInteractivePrompts ? Data([2]) : Data([0]) + Data("自动重连需要交互认证，请手动重新连接。\n".utf8)
                }
                lock.lock(); let canReply = !stopped; lock.unlock()
                if canReply { _ = SSHAskpass.write(response, to: socket) }
            }
            lock.lock(); active = -1; close(socket); lock.unlock()
        }
    }

    private static func codeHash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

    private func helperHasExpectedSignature(_ pid: pid_t) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        return Self.codeHash(staticCode) == executableHash
    }

    deinit { stop() }
}
