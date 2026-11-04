import Foundation
import Darwin
import Nc2ShellCore

/// 独立复用通道只读取环境；每次至多一个请求，远端 stdin EOF 即结束观察。
final class DirectoryFollowMonitor: @unchecked Sendable {
    private let arguments: [String]
    private let token: String
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false

    init(profile: ConnectionProfile, controlPath: String, context: ShellContext, token: String) throws {
        arguments = try ShellContextProbe.arguments(profile: profile, controlPath: controlPath, context: context, token: token)
        self.token = token
    }

    func start(_ receive: @escaping @Sendable (Result<ShellContextProbe.Event, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do { try self.observe(receive) }
            catch { if !self.isCancelled { receive(.failure(error)) } }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    private func observe(_ receive: @escaping @Sendable (Result<ShellContextProbe.Event, Error>) -> Void) throws {
        let process = Process(), incoming = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = incoming; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        _ = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        do { try process.run(); child = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        try? incoming.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        defer {
            try? incoming.fileHandleForWriting.close()
            lock.lock()
            if process.isRunning { process.terminate() }
            child = nil
            lock.unlock()
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        var decoder = ShellContextProbe.Decoder(token: token)
        var sentAt: TimeInterval?, nextTick: TimeInterval = 0
        while !isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            if let sentAt, now - sentAt >= 5 { throw ProfileError("目录观察超时；暂停后恢复跟随可重试。") }
            if sentAt == nil, now >= nextTick {
                try incoming.fileHandleForWriting.write(contentsOf: Data("tick\n".utf8))
                sentAt = now; nextTick = now + 1
            }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ProfileError("无法读取目录观察通道。")
            }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd.fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ProfileError("目录观察通道已结束；暂停后恢复跟随可重试。") }
            for event in try decoder.feed(Data(buffer.prefix(count))) {
                sentAt = nil
                if !isCancelled { receive(.success(event)) }
            }
        }
    }
}
