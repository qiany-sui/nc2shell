import Foundation
import Darwin
import Nc2ShellCore

/// -G 会评估配置（含 Match exec）；动态规则和代理链都保守交给手动连接。
final class SSHReconnectPreflight: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t = 0
    private var cancelled = false

    func run(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.check(arguments); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true
        // 进程尚未回收，组号仍属于这次检查；不能只终止 SSH 而遗留 Match exec。
        if processID > 0 { kill(-processID, SIGTERM) }
        lock.unlock()
    }

    private func check(_ arguments: [String]) throws {
        let pipe = Pipe(), null = FileHandle.nullDevice
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes); posix_spawn_file_actions_init(&actions)
        defer { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_adddup2(&actions, null.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let argv = (["/usr/bin/ssh", "-vv", "-G"] + arguments).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw ProfileError("已取消自动重连。") }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, "/usr/bin/ssh", &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        if result == 0 { processID = pid }
        lock.unlock()
        guard result == 0 else { throw ProfileError("无法检查 SSH 配置，请手动重新连接。") }
        try? pipe.fileHandleForWriting.close()
        defer {
            lock.lock()
            // waitid(WNOWAIT) 保留父进程身份，清理全组后才 waitpid，避免向复用的组号发信号。
            kill(-pid, SIGKILL); processID = 0
            lock.unlock()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var data = Data(), ended = false
        var exitInfo = siginfo_t()
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            guard !stopped else { throw ProfileError("已取消自动重连。") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProfileError("检查 SSH 配置超时，请手动重新连接。") }
            let waited = waitid(P_PID, id_t(pid), &exitInfo, WEXITED | WNOHANG | WNOWAIT)
            if waited < 0 && errno != EINTR { throw ProfileError("无法确认 SSH 配置检查状态，请手动重新连接。") }
            if ended, exitInfo.si_pid == pid { break }
            if ended { Thread.sleep(forTimeInterval: 0.01); continue }
            var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ProfileError("无法检查 SSH 配置，请手动重新连接。")
            }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(descriptor.fd, &buffer, buffer.count)
            if count == 0 { ended = true; continue }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProfileError("无法读取 SSH 配置，请手动重新连接。")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 262_144 else { throw ProfileError("SSH 配置输出过大，请手动重新连接。") }
        }
        guard exitInfo.si_code == CLD_EXITED, exitInfo.si_status == 0,
              let output = String(data: data, encoding: .utf8), output.contains("\nhostname ") else {
            throw ProfileError("无法确认 SSH 有效配置，请手动重新连接。")
        }
        // 不重用动态求值结果；它可能依赖 PTY 或外部状态，第二次求值会改变连接目标。
        if output.contains("debug2: checking match for ") {
            throw ProfileError("此连接使用 SSH Match 动态配置，自动重连已停止；请手动重新连接。")
        }
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[0] == "proxyjump" || fields[0] == "proxycommand",
               fields[1].lowercased() != "none" {
                throw ProfileError("此连接使用 SSH 代理或跳板，自动重连已停止；请手动重新连接以处理独立认证。")
            }
        }
    }
}
