import Foundation
import Darwin
import CryptoKit

/// OpenSSH 承担认证与加密；这里只处理 SFTP 子系统的有长度数据，文件名不进入 Shell。
public final class SFTPClient: @unchecked Sendable {
    public typealias Progress = @Sendable (UInt64) -> Void
    private let queue = DispatchQueue(label: "com.nc2oding.sftp", qos: .userInitiated)
    private let lock = NSCondition()
    private var cancelled = false
    private var paused = false
    private var conflictWait: ConflictDecisionWait?
    private var child: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let arguments: [String]
    private let bandwidthLimiter: TransferBandwidthLimiter?
    private let requestWindow: Int
    private var sequence: UInt32 = 0

    public init(profile: ConnectionProfile, controlPath: String, bandwidthLimiter: TransferBandwidthLimiter? = nil,
                requestWindow: Int = 16) throws {
        arguments = try Self.arguments(profile: profile, controlPath: controlPath)
        self.bandwidthLimiter = bandwidthLimiter
        self.requestWindow = min(16, max(1, requestWindow))
    }

    public static func arguments(profile: ConnectionProfile, controlPath: String) throws -> [String] {
        let profile = try profile.validated()
        // 不读取配置或回退建连；socket 失效时必须失败，不能再次认证或执行 ProxyJump。
        var args = ["-F", "/dev/null", "-T", "-p", String(profile.port), "-S", controlPath,
                    "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false",
                    "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-s"]
        if !profile.username.isEmpty { args += ["-l", profile.username] }
        return args + ["--", profile.host, "sftp"]
    }

    public func list(path: String) async throws -> (path: String, files: [RemoteFile]) {
        try await perform {
            let canonical = try self.canonicalPath(path)
            return (canonical, try self.readDirectory(canonical))
        }
    }

    public func search(directory: String, query: String, includeHidden: Bool,
                       progress: @escaping @Sendable (RemoteSearchSnapshot) -> Void = { _ in }) async throws -> RemoteSearchSnapshot {
        guard !query.isEmpty, !query.contains("\0") else { throw SFTPError.message("搜索名称不能为空或包含空字符。") }
        return try await perform {
            var result = RemoteSearchSnapshot()
            var lastReport = ProcessInfo.processInfo.systemUptime
            func skip(_ path: String, _ reason: String) {
                result.skippedCount += 1
                if result.issues.count < 100 { result.issues.append(.init(path: path, reason: reason)) }
            }
            func scan(_ path: String, depth: Int) throws {
                try self.checkCancellation()
                guard depth < 64 else { skip(path, "文件夹嵌套达到 64 层，未继续深入。"); return }
                result.currentDirectory = path
                if ProcessInfo.processInfo.systemUptime - lastReport >= 0.1 {
                    progress(result); lastReport = ProcessInfo.processInfo.systemUptime
                }
                let entries: [RemoteFile]
                do {
                    // 每层重新检查规范路径和类型，避免按目录列表中的旧类型进入链接。
                    try self.requireDirectory(path)
                    entries = try self.readDirectory(path)
                } catch SFTPError.status(let code, let reason) where depth > 0 && (code == 2 || code == 3) {
                    skip(path, SFTPError.status(code, reason).localizedDescription)
                    return
                }
                for entry in entries where includeHidden || !entry.name.hasPrefix(".") {
                    try self.checkCancellation()
                    result.scannedCount += 1
                    let child = RemoteFile.join(path, entry.name)
                    if entry.name.range(of: query, options: .caseInsensitive) != nil {
                        result.matches.append(.init(path: child, file: entry))
                        if result.matches.count == 1000 { result.truncated = true; return }
                    }
                    if entry.kind == .directory { try scan(child, depth: depth + 1) }
                    if result.truncated { return }
                    if ProcessInfo.processInfo.systemUptime - lastReport >= 0.1 {
                        progress(result); lastReport = ProcessInfo.processInfo.systemUptime
                    }
                }
            }
            do { try scan(directory, depth: 0) }
            catch { progress(result); throw error }
            progress(result)
            return result
        }
    }

    public func estimateUploadBytes(_ urls: [URL]) async throws -> UInt64? {
        try await performEstimate {
            try self.estimatedSum(urls) { try self.estimateLocalTree($0, depth: 0) }
        }
    }

    public func estimateDownloadBytes(_ paths: [String]) async throws -> UInt64? {
        try await performEstimate {
            try self.estimatedSum(paths) { try self.estimateRemoteTree($0, depth: 0) }
        }
    }

    public func createDirectory(in directory: String, name: String) async throws {
        try RemoteFile.validateName(name)
        try await perform {
            try self.requireDirectory(directory)
            let target = RemoteFile.join(directory, name)
            try self.requireMissing(target)
            var body = SFTPWriter(); body.text(target); body.uint32(0)
            _ = try self.request(14, body, expecting: 101)
        }
    }

    public func rename(_ file: RemoteFile, in directory: String, to name: String) async throws {
        try RemoteFile.validateName(file.name); try RemoteFile.validateName(name)
        try await perform {
            try self.requireDirectory(directory)
            let source = RemoteFile.join(directory, file.name)
            try self.requireUnchangedKind(file, at: source)
            guard file.name != name else { return }
            let target = RemoteFile.join(directory, name)
            try self.requireMissing(target)
            var body = SFTPWriter(); body.text(source); body.text(target)
            // 使用 v3 RENAME 的不覆盖语义，不启用 posix-rename 扩展。
            _ = try self.request(18, body, expecting: 101)
        }
    }

    public func setPermissions(_ file: RemoteFile, in directory: String, permissions: UInt32) async throws {
        try RemoteFile.validateName(file.name)
        let mode = try RemotePermissions.mode(original: file.mode, permissions: permissions)
        guard file.kind == .file || file.kind == .directory else { throw SFTPError.message("只能修改普通文件或文件夹的权限。") }
        try await perform {
            try self.requireDirectory(directory)
            let path = RemoteFile.join(directory, file.name)
            guard try self.stat(path) == file else { throw SFTPError.message("远程项目已变化，请刷新后重新确认：\(path)") }
            guard mode != file.mode & 0o7777 else { return }
            var body = SFTPWriter(); body.text(path); body.uint32(4); body.uint32(mode)
            do {
                // 只发送权限字段，不能顺带改变长度、所有者或时间。
                _ = try self.request(9, body, expecting: 101)
                let actual = try self.stat(path)
                guard actual.kind == file.kind, actual.mode & 0o7777 == mode else {
                    throw SFTPError.message("服务器返回的权限与所设权限不一致。")
                }
            } catch {
                throw SFTPError.message("修改权限未确认完成：\(path)\n\(error.localizedDescription)\n权限可能已生效，请刷新确认。")
            }
        }
    }

    public func delete(_ file: RemoteFile, in directory: String) async throws {
        try RemoteFile.validateName(file.name)
        try await perform {
            try self.requireDirectory(directory)
            let target = RemoteFile.join(directory, file.name)
            try self.requireUnchangedKind(file, at: target)
            do { try self.deleteTree(target, depth: 0) }
            catch { throw SFTPError.message("删除 \(target) 未完成：\(error.localizedDescription)\n部分内容可能已永久删除，无法撤销。") }
        }
    }

    @discardableResult
    public func upload(local: URL, remote: String, progress: @escaping Progress = { _ in }) async throws -> UInt64 {
        try await perform {
            try self.requireMissing(remote)
            let parent = (remote as NSString).deletingLastPathComponent
            let temporary = RemoteFile.join(parent, ".nc2shell-upload-\(UUID().uuidString)")
            var total: UInt64 = 0
            do {
                try self.uploadTree(local, temporary, depth: 0, total: &total, progress: progress)
                var body = SFTPWriter(); body.text(temporary); body.text(remote)
                // v3 RENAME 必须在目标存在时失败；不使用会覆盖目标的 posix-rename 扩展。
                _ = try self.request(18, body, expecting: 101)
                return total
            } catch {
                throw SFTPError.message("\(error.localizedDescription)\n未完成内容可能保留在：\(temporary)")
            }
        }
    }

    public func download(remote: String, local: URL, progress: @escaping Progress = { _ in }) async throws {
        try await perform {
            let manager = FileManager.default
            guard !manager.fileExists(atPath: local.path) else { throw SFTPError.message("本地已存在同名文件或目录，请换一个名称。") }
            let staging = local.deletingLastPathComponent().appendingPathComponent(".nc2shell-download-\(UUID().uuidString)")
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: staging) }
            let target = staging.appendingPathComponent("content")
            var total: UInt64 = 0
            try self.downloadTree(remote, target, depth: 0, total: &total, progress: progress)
            try self.checkCancellation()
            try manager.moveItem(at: target, to: local)
        }
    }

    @discardableResult
    public func upload(local: URL, remote: String, resolveConflict: @escaping TransferConflictResolver,
                       checkpoint: TransferCheckpoint? = nil, progress: @escaping Progress = { _ in }) async throws -> TransferResult {
        try await perform {
            if let checkpoint {
                return try self.transferResuming(source: local.path, requested: remote, upload: true, canKeepBoth: true,
                                                 checkpoint: checkpoint, resolver: resolveConflict, progress: progress)
            }
            var bytes: UInt64 = 0, skipped = 0
            try self.uploadResolving(local, remote, depth: 0, bytes: &bytes, skipped: &skipped,
                                     resolver: resolveConflict, progress: progress)
            return TransferResult(bytes: bytes, skippedCount: skipped)
        }
    }

    @discardableResult
    public func download(remote: String, local: URL, resolveConflict: @escaping TransferConflictResolver,
                         allowRootRename: Bool = true, checkpoint: TransferCheckpoint? = nil, progress: @escaping Progress = { _ in }) async throws -> TransferResult {
        try await perform {
            if let checkpoint {
                return try self.transferResuming(source: remote, requested: local.path, upload: false, canKeepBoth: allowRootRename,
                                                 checkpoint: checkpoint, resolver: resolveConflict, progress: progress)
            }
            var bytes: UInt64 = 0, skipped = 0
            try self.downloadResolving(remote, local, depth: 0, bytes: &bytes, skipped: &skipped,
                                       canKeepBoth: allowRootRename, resolver: resolveConflict, progress: progress)
            return TransferResult(bytes: bytes, skippedCount: skipped)
        }
    }

    @discardableResult
    public func move(_ file: RemoteFile, from directory: String, toDirectory: String,
                     resolveConflict: @escaping TransferConflictResolver, progress: @escaping Progress = { _ in }) async throws -> TransferResult {
        try await relocate(file, from: directory, toDirectory: toDirectory, copying: false, resolver: resolveConflict, progress: progress)
    }

    @discardableResult
    public func copy(_ file: RemoteFile, from directory: String, toDirectory: String,
                     resolveConflict: @escaping TransferConflictResolver, progress: @escaping Progress = { _ in }) async throws -> TransferResult {
        try await relocate(file, from: directory, toDirectory: toDirectory, copying: true, resolver: resolveConflict, progress: progress)
    }

    public func setPaused(_ paused: Bool) {
        lock.lock()
        self.paused = paused
        lock.broadcast()
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        let process = child
        let waiting = conflictWait
        lock.unlock()
        waiting?.cancel()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    deinit { cancel(); try? input?.close(); try? output?.close() }

    func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { try self.waitUntilResumed(); try self.start(); continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw SFTPError.message("传输已取消或连接已断开。") }
    }

    func waitUntilResumed() throws {
        lock.lock()
        while paused && !cancelled { lock.wait() }
        let stopped = cancelled
        lock.unlock()
        if stopped { throw SFTPError.message("传输已取消或连接已断开。") }
    }

    private func start() throws {
        if child != nil { return }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.cancel() }
        // 管道关闭时返回 EPIPE，不能让远端断开导致整个应用收到 SIGPIPE。
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lock.lock()
        guard !cancelled else { lock.unlock(); throw SFTPError.message("文件连接已取消。") }
        do { try process.run() } catch { lock.unlock(); throw error }
        child = process
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        lock.unlock()
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        var hello = SFTPWriter(); hello.byte(1); hello.uint32(3)
        try writePacket(hello.data)
        var reply = SFTPReader(try readPacket())
        guard try reply.byte() == 2, try reply.uint32() == 3 else { throw SFTPError.message("服务器不支持 SFTP v3。") }
    }

    private func writePacket(_ data: Data) throws {
        var framed = SFTPWriter(); framed.string(data)
        guard let input else { throw SFTPError.message("文件连接未建立。") }
        try input.write(contentsOf: framed.data)
    }

    private func readBytes(_ count: Int, checkCancelled: Bool) throws -> Data {
        guard let output else { throw SFTPError.message("文件连接未建立。") }
        var result = Data()
        let deadline = Date().addingTimeInterval(30)
        while result.count < count {
            if checkCancelled { try checkCancellation() }
            guard Date() < deadline else { throw SFTPError.message("文件服务器响应超时。") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 { if errno == EINTR { continue }; throw SFTPError.message("读取文件连接失败。") }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: min(count - result.count, 65536))
            let readCount = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw SFTPError.message("SFTP 通道已关闭，请确认服务器启用了 SFTP 并重新连接。") }
            result.append(contentsOf: buffer.prefix(readCount))
        }
        return result
    }

    private func readPacket(checkCancelled: Bool = true) throws -> Data {
        var header = SFTPReader(try readBytes(4, checkCancelled: checkCancelled))
        let count = try header.uint32()
        guard count > 0, count <= 1_048_576 else { throw SFTPError.message("SFTP 响应长度无效。") }
        return try readBytes(Int(count), checkCancelled: checkCancelled)
    }

    func request(_ type: UInt8, _ body: SFTPWriter, expecting: UInt8) throws -> SFTPReader {
        // 已发送请求仍完整读完响应，暂停时间不计入服务器响应超时。
        try waitUntilResumed()
        sequence &+= 1
        var packet = SFTPWriter(); packet.byte(type); packet.uint32(sequence); packet.data.append(body.data)
        try writePacket(packet.data)
        var response = SFTPReader(try readPacket())
        let received = try response.byte()
        guard try response.uint32() == sequence else { throw SFTPError.message("SFTP 响应序号不匹配。") }
        if received == 101 {
            let code = try response.uint32(), message = try response.text()
            if code != 0 { throw SFTPError.status(code, message) }
        }
        guard received == expecting else { throw SFTPError.message("SFTP 返回了意外响应。") }
        return response
    }

    private struct PayloadRequest {
        let type: UInt8
        let body: SFTPWriter
        let expecting: UInt8
        var uploadBytes = 0
        var downloadBytes = 0
    }

    private func payloadResponses(_ requests: [PayloadRequest]) throws -> [Result<SFTPReader, Error>] {
        var positions: [UInt32: Int] = [:]
        var results = [Result<SFTPReader, Error>?](repeating: nil, count: requests.count)
        do {
            for (index, request) in requests.enumerated() {
                try waitUntilResumed()
                if request.uploadBytes > 0 { try acquirePayload(request.uploadBytes, direction: .upload) }
                if request.downloadBytes > 0 { try acquirePayload(request.downloadBytes, direction: .download) }
                sequence &+= 1
                positions[sequence] = index
                var packet = SFTPWriter(); packet.byte(request.type); packet.uint32(sequence); packet.data.append(request.body.data)
                try writePacket(packet.data)
            }
            // 完整收齐窗口再处理回调，暂停、保存检查点或应用层错误不会留下未读响应。
            for _ in requests {
                var response = SFTPReader(try readPacket())
                let type = try response.byte(), id = try response.uint32()
                guard let index = positions.removeValue(forKey: id) else { throw SFTPError.message("SFTP 响应序号重复或不匹配。") }
                if type == 101 {
                    let code = try response.uint32(), message = try response.text()
                    if code != 0 {
                        bandwidthLimiter?.refundUnusedReadBytes(requests[index].downloadBytes)
                        results[index] = .failure(SFTPError.status(code, message)); continue
                    }
                }
                guard type == requests[index].expecting else { throw SFTPError.message("SFTP 返回了意外响应。") }
                if requests[index].downloadBytes > 0 {
                    var copy = response
                    let count = try copy.string().count
                    guard count > 0, count <= requests[index].downloadBytes else { throw SFTPError.message("文件数据长度无效。") }
                    bandwidthLimiter?.refundUnusedReadBytes(requests[index].downloadBytes - count)
                }
                results[index] = .success(response)
            }
        } catch {
            // 协议错误、断线和取消无法保证响应边界，不能在这个通道继续 CLOSE 或新操作。
            cancel()
            throw error
        }
        return results.map { $0! }
    }

    private func acquirePayload(_ count: Int, direction: TransferTrafficDirection) throws {
        try waitUntilResumed()
        try bandwidthLimiter?.acquire(bytes: count, direction: direction, check: { try self.waitUntilResumed() })
    }

    private func payloadWindow(_ direction: TransferTrafficDirection) -> Int {
        guard let rate = bandwidthLimiter?.limit(for: direction), rate > 0 else { return requestWindow }
        // 低速时缩短批次，避免等满 16 块额度后才显示第一块进度。
        return Int(min(UInt64(requestWindow), max(1, rate / (4 * 32768))))
    }

    private func writePayload(_ chunks: [(offset: UInt64, data: Data)], handle: Data,
                              confirmed: (UInt64, Data) throws -> Void) throws {
        var requests: [PayloadRequest] = []
        for chunk in chunks {
            var body = SFTPWriter(); body.string(handle); body.uint64(chunk.offset); body.string(chunk.data)
            requests.append(PayloadRequest(type: 6, body: body, expecting: 101, uploadBytes: chunk.data.count))
        }
        let responses = try payloadResponses(requests)
        for (index, result) in responses.enumerated() {
            try waitUntilResumed()
            _ = try result.get()
            // 只把从低偏移开始连续确认的 WRITE 交给进度和检查点。
            try confirmed(chunks[index].offset, chunks[index].data)
        }
    }

    @discardableResult
    private func readPayload(_ handle: Data, offset start: UInt64 = 0, limit: UInt64? = nil,
                             consume: (UInt64, Data) throws -> Void) throws -> UInt64 {
        var offset = start
        while limit.map({ offset < $0 }) ?? true {
            var offsets: [UInt64] = [], lengths: [Int] = [], data: [Data] = [], ended: [Bool] = []
            for _ in 0..<payloadWindow(.download) {
                let next = offset + UInt64(offsets.count * 32768)
                if let limit, next >= limit { break }
                offsets.append(next); lengths.append(Int(min(32768, limit.map { $0 - next } ?? 32768)))
                data.append(Data()); ended.append(false)
            }
            while true {
                let pending = offsets.indices.filter { !ended[$0] && data[$0].count < lengths[$0] }
                if pending.isEmpty { break }
                let requests = pending.map { index -> PayloadRequest in
                    var body = SFTPWriter(); body.string(handle); body.uint64(offsets[index] + UInt64(data[index].count))
                    body.uint32(UInt32(lengths[index] - data[index].count))
                    return PayloadRequest(type: 5, body: body, expecting: 103, downloadBytes: lengths[index] - data[index].count)
                }
                let responses = try payloadResponses(requests)
                for (index, result) in zip(pending, responses) {
                    do {
                        var reply = try result.get()
                        let part = try reply.string()
                        guard !part.isEmpty, part.count <= lengths[index] - data[index].count else { throw SFTPError.message("文件数据长度无效。") }
                        data[index].append(part)
                    } catch SFTPError.status(1, _) {
                        ended[index] = true
                        if limit != nil { throw SFTPError.message("来源长度已变化，读取在预期长度之前结束。") }
                    }
                }
            }
            var eof = false
            for index in offsets.indices {
                guard !eof || data[index].isEmpty else { throw SFTPError.message("SFTP 在文件结束之后返回了数据。") }
                if !data[index].isEmpty {
                    try waitUntilResumed()
                    try consume(offsets[index], data[index])
                    offset += UInt64(data[index].count)
                }
                eof = eof || ended[index]
            }
            if eof { break }
        }
        return offset
    }

    private func uploadPayload(_ source: FileHandle, handle: Data, offset start: UInt64 = 0,
                               confirmed: (UInt64, Data) throws -> Void) throws {
        var offset = start, finished = false
        try source.seek(toOffset: offset)
        while !finished {
            var chunks: [(offset: UInt64, data: Data)] = []
            for _ in 0..<payloadWindow(.upload) {
                try waitUntilResumed()
                let data = try source.read(upToCount: 32768) ?? Data()
                if data.isEmpty { finished = true; break }
                chunks.append((offset, data)); offset += UInt64(data.count)
            }
            if !chunks.isEmpty { try writePayload(chunks, handle: handle, confirmed: confirmed) }
        }
    }

    private func close(_ handle: Data) throws {
        var body = SFTPWriter(); body.string(handle)
        _ = try request(4, body, expecting: 101)
    }

    private func stat(_ path: String) throws -> RemoteFile {
        var body = SFTPWriter(); body.text(path)
        var response = try request(7, body, expecting: 105)
        let attrs = try response.attributes()
        return RemoteFile(name: (path as NSString).lastPathComponent, size: attrs.size, mode: attrs.mode, modifiedTime: attrs.modifiedTime, hasSize: attrs.hasSize)
    }

    private func canonicalPath(_ path: String) throws -> String {
        var body = SFTPWriter(); body.text(path)
        var response = try request(16, body, expecting: 104)
        guard try response.uint32() == 1 else { throw SFTPError.message("服务器返回了无效的目录路径。") }
        let canonical = try response.text()
        guard canonical.hasPrefix("/"), !canonical.contains("\0") else { throw SFTPError.message("目录路径必须是绝对路径。") }
        return canonical
    }

    private func requireDirectory(_ directory: String) throws {
        guard directory.hasPrefix("/"), !directory.contains("\0"),
              !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SFTPError.message("目录路径无效，请刷新后重试。")
        }
        // 目录或其祖先被换成链接时拒绝操作，避免递归进入另一个目标。
        guard try canonicalPath(directory) == directory, try stat(directory).kind == .directory else {
            throw SFTPError.message("远程目录已变化，请刷新后重试。")
        }
    }

    private func requireUnchangedKind(_ file: RemoteFile, at path: String) throws {
        guard file.kind == .file || file.kind == .directory else { throw SFTPError.message("暂不操作符号链接或特殊文件。") }
        guard try stat(path).kind == file.kind else { throw SFTPError.message("远程项目类型已变化，请刷新后重试。") }
    }

    private func deleteTree(_ path: String, depth: Int) throws {
        try checkCancellation()
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        try requireDirectory((path as NSString).deletingLastPathComponent)
        let entry = try stat(path)
        if entry.kind == .directory {
            try requireDirectory(path)
            for child in try readDirectory(path) {
                try deleteTree(RemoteFile.join(path, child.name), depth: depth + 1)
            }
            try requireDirectory(path)
            var body = SFTPWriter(); body.text(path)
            _ = try request(15, body, expecting: 101)
        } else if entry.kind == .file || entry.kind == .symbolicLink {
            // REMOVE 删除链接本身；绝不遍历链接指向的文件或目录。
            var body = SFTPWriter(); body.text(path)
            _ = try request(13, body, expecting: 101)
        } else { throw SFTPError.message("暂不删除特殊文件：\(path)") }
    }

    private func requireMissing(_ path: String) throws {
        do { _ = try stat(path) }
        catch SFTPError.status(2, _) { return }
        throw SFTPError.message("远端已存在同名文件或目录，请更换名称或目标目录。")
    }

    private func readDirectory(_ path: String) throws -> [RemoteFile] {
        var body = SFTPWriter(); body.text(path)
        var opened = try request(11, body, expecting: 102)
        let handle = try opened.string()
        defer { try? close(handle) }
        body = SFTPWriter(); body.string(handle)
        var files: [RemoteFile] = [], names = Set<String>()
        while true {
            var response: SFTPReader
            do { response = try request(12, body, expecting: 104) }
            catch SFTPError.status(1, _) { break }
            let count = try response.uint32()
            guard count > 0, count <= 100_000, files.count + Int(count) <= 100_000 else { throw SFTPError.message("目录条目过多或响应无效。") }
            for _ in 0..<count {
                let name = try response.text(); _ = try response.string()
                let attrs = try response.attributes()
                if name == "." || name == ".." { continue }
                try RemoteFile.validateName(name)
                guard names.insert(name).inserted else { throw SFTPError.message("服务器返回了重复文件名。") }
                files.append(RemoteFile(name: name, size: attrs.size, mode: attrs.mode, modifiedTime: attrs.modifiedTime, hasSize: attrs.hasSize))
            }
        }
        return files.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func performEstimate(_ operation: @escaping () throws -> UInt64?) async throws -> UInt64? {
        try await perform {
            do {
                let result = try operation()
                try self.waitUntilResumed()
                return result
            } catch {
                // 估算不能抢先阻止后续的冲突跳过；只有取消或通道中断必须继续抛出。
                try self.checkCancellation()
                if case SFTPError.status(let code, _) = error, code == 6 || code == 7 { throw error }
                guard self.child?.isRunning == true else { throw error }
                if let output = self.output {
                    // EOF 可能早于进程退出回调，不能把此时的断线误报为未知总量。
                    var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    if poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                        throw error
                    }
                }
                return nil
            }
        }
    }

    private func estimatedSum<T>(_ sources: [T], estimate: (T) throws -> UInt64?) throws -> UInt64? {
        var total: UInt64 = 0
        for source in sources {
            try waitUntilResumed()
            guard let bytes = try estimate(source) else { return nil }
            let sum = total.addingReportingOverflow(bytes)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    private func estimateLocalTree(_ url: URL, depth: Int) throws -> UInt64? {
        try waitUntilResumed()
        guard depth < 64, url.isFileURL else { return nil }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular:
            guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else { return nil }
            return size.uint64Value
        case .typeDirectory:
            let children = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return try estimatedSum(children) { try self.estimateLocalTree($0, depth: depth + 1) }
        default:
            return nil
        }
    }

    private func estimateRemoteTree(_ path: String, depth: Int) throws -> UInt64? {
        try waitUntilResumed()
        guard depth < 64 else { return nil }
        try requireDirectory((path as NSString).deletingLastPathComponent)
        let item = try stat(path)
        switch item.kind {
        case .file:
            return item.hasSize ? item.size : nil
        case .directory:
            try requireDirectory(path)
            return try estimatedSum(readDirectory(path)) {
                try self.estimateRemoteTree(RemoteFile.join(path, $0.name), depth: depth + 1)
            }
        default:
            return nil
        }
    }

    private func uploadTree(_ local: URL, _ remote: String, depth: Int, total: inout UInt64, progress: Progress) throws {
        try checkCancellation()
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        let kind = attributes[.type] as? FileAttributeType
        if kind == .typeDirectory {
            var body = SFTPWriter(); body.text(remote); body.uint32(0)
            _ = try request(14, body, expecting: 101)
            for entry in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try RemoteFile.validateName(entry.lastPathComponent)
                try uploadTree(entry, RemoteFile.join(remote, entry.lastPathComponent), depth: depth + 1, total: &total, progress: progress)
            }
        } else if kind == .typeRegular {
            let file = try FileHandle(forReadingFrom: local)
            defer { try? file.close() }
            var body = SFTPWriter(); body.text(remote); body.uint32(2 | 8 | 32); body.uint32(0)
            var response = try request(3, body, expecting: 102)
            let handle = try response.string()
            var closed = false
            defer { if !closed { try? close(handle) } }
            try uploadPayload(file, handle: handle) { _, data in
                total += UInt64(data.count); progress(total)
            }
            try close(handle); closed = true
        } else { throw SFTPError.message("暂不传输符号链接或特殊文件：\(local.lastPathComponent)") }
    }

    private func downloadTree(_ remote: String, _ local: URL, depth: Int, total: inout UInt64, progress: Progress) throws {
        try checkCancellation()
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        let entry = try stat(remote)
        if entry.kind == .directory {
            guard mkdir(local.path, 0o700) == 0 else { throw SFTPError.message("无法创建本地目录，可能有大小写不同的同名条目。") }
            for entry in try readDirectory(remote) {
                try downloadTree(RemoteFile.join(remote, entry.name), local.appendingPathComponent(entry.name), depth: depth + 1, total: &total, progress: progress)
            }
        } else if entry.kind == .file {
            let descriptor = Darwin.open(local.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw SFTPError.message("无法创建本地文件，可能有大小写不同的同名条目。") }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var body = SFTPWriter(); body.text(remote); body.uint32(1); body.uint32(0)
            var response = try request(3, body, expecting: 102)
            let handle = try response.string()
            defer { try? close(handle) }
            try readPayload(handle, limit: entry.hasSize ? entry.size : nil) { offset, data in
                try file.seek(toOffset: offset)
                try file.write(contentsOf: data)
                total += UInt64(data.count); progress(total)
            }
            guard try stat(remote) == entry else {
                throw SFTPError.message("下载来源在传输期间已变化：\(remote)")
            }
            try file.synchronize()
        } else { throw SFTPError.message("暂不下载符号链接或特殊文件：\(entry.name)") }
    }

    // SFTP 的阻塞读写和等待均留在串行队列；用户选择在独立 Task 中进入 MainActor。
    private func resolve(_ conflict: TransferConflict, with resolver: @escaping TransferConflictResolver) throws -> TransferConflictChoice {
        let waiting = ConflictDecisionWait()
        lock.lock()
        if cancelled { lock.unlock(); try checkCancellation() }
        else { conflictWait = waiting; lock.unlock() }
        defer { lock.lock(); conflictWait = nil; lock.unlock() }
        let task = Task.detached {
            do { waiting.finish(.success(try await resolver(conflict))) }
            catch { waiting.finish(.failure(error)) }
        }
        waiting.attach(task)
        let choice = try waiting.wait()
        try checkCancellation()
        if choice == .cancel { throw SFTPError.message("传输已取消。") }
        if choice == .merge && !(conflict.sourceIsDirectory && conflict.destinationIsDirectory) {
            throw SFTPError.message("只有两个文件夹才可以合并。")
        }
        if choice == .keepBoth && !conflict.canKeepBoth {
            throw SFTPError.message("Finder 已指定最终名称，不能更改拖出项目的目标。")
        }
        return choice
    }

    private func remoteItem(_ path: String) throws -> RemoteFile? {
        do { return try stat(path) } catch SFTPError.status(2, _) { return nil }
    }

    private func requireTransferable(_ item: RemoteFile, at path: String) throws {
        guard item.kind == .file || item.kind == .directory else {
            throw SFTPError.message("暂不传输或覆盖符号链接及特殊文件：\(path)")
        }
    }

    private func requireRemoteSnapshot(_ snapshot: RemoteFile?, at path: String) throws {
        guard try remoteItem(path) == snapshot else {
            throw SFTPError.message("目标项目在等待或传输期间已变化，请刷新后重试：\(path)")
        }
    }

    private func renamePath(_ source: String, to target: String) throws {
        var body = SFTPWriter(); body.text(source); body.text(target)
        _ = try request(18, body, expecting: 101)
    }

    private func copyName(_ name: String, directory: Bool, index: Int) -> String {
        TransferCheckpoint.copyName(name, directory: directory, index: index)
    }

    private func relocate(_ file: RemoteFile, from directory: String, toDirectory: String, copying: Bool,
                          resolver: @escaping TransferConflictResolver, progress: @escaping Progress) async throws -> TransferResult {
        try RemoteFile.validateName(file.name)
        guard toDirectory.hasPrefix("/"), !toDirectory.contains("\0") else { throw SFTPError.message("目标目录必须是绝对路径。") }
        return try await perform {
            try self.requireDirectory(directory)
            let destination = try self.canonicalPath(toDirectory)
            let source = RemoteFile.join(directory, file.name), target = RemoteFile.join(destination, file.name)
            try self.requireDirectory(destination)
            let current = try self.stat(source)
            // READDIR 可以缺少可选属性，只比较用户选择时实际已知的值。
            guard current.mode == file.mode, (!file.hasSize || (current.hasSize && current.size == file.size)),
                  file.modifiedTime == nil || current.modifiedTime == file.modifiedTime else {
                throw SFTPError.message("来源项目已变化，请刷新后重试：\(source)")
            }
            try self.requireTransferable(file, at: source)
            guard source != target, !source.hasPrefix(target + "/"),
                  !(file.kind == .directory && (destination == source || destination.hasPrefix(source + "/"))) else {
                throw SFTPError.message("不能将项目移动或复制到自身、后代目录或覆盖其父目录。")
            }
            // 目录 rename 也先检查整棵树，避免绕过复制流程中的链接与特殊文件限制。
            _ = try self.inspectRemoteTree(source, depth: 0)
            try self.requireRemoteSnapshot(current, at: source)
            let validateLocation = {
                try self.requireDirectory(directory)
                guard try self.canonicalPath(toDirectory) == destination else { throw SFTPError.message("目标目录在操作期间已变化。") }
                try self.requireDirectory(destination)
            }
            var bytes: UInt64 = 0, skipped = 0
            do {
                try self.relocateResolving(source, target, copying: copying, depth: 0, bytes: &bytes, skipped: &skipped,
                                           resolver: resolver, progress: progress, validateLocation: validateLocation)
                return TransferResult(bytes: bytes, skippedCount: skipped)
            } catch {
                throw SFTPError.message("\(copying ? "复制" : "移动")未完成：\(error.localizedDescription)\n来源：\(source)\n目标：\(target)\n部分项目可能已生效，请刷新确认；已完成内容不会回滚。")
            }
        }
    }

    private func inspectRemoteTree(_ path: String, depth: Int) throws -> UInt64 {
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        try requireDirectory((path as NSString).deletingLastPathComponent)
        let item = try stat(path)
        try requireTransferable(item, at: path)
        if item.kind == .file { return item.size }
        try requireDirectory(path)
        var bytes: UInt64 = 0
        for child in try readDirectory(path) {
            bytes += try inspectRemoteTree(RemoteFile.join(path, child.name), depth: depth + 1)
        }
        return bytes
    }

    private func relocateResolving(_ source: String, _ requested: String, copying: Bool, depth: Int,
                                   bytes: inout UInt64, skipped: inout Int, resolver: @escaping TransferConflictResolver,
                                   progress: Progress, validateLocation: () throws -> Void) throws {
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        try validateLocation()
        let sourceParent = (source as NSString).deletingLastPathComponent
        let parent = (requested as NSString).deletingLastPathComponent
        try requireDirectory(sourceParent); try requireDirectory(parent)
        let item = try stat(source)
        try requireTransferable(item, at: source)
        var target = requested, existing = try remoteItem(target)
        if let destination = existing {
            try requireTransferable(destination, at: target)
            let choice = try resolve(TransferConflict(sourcePath: source, destinationPath: target,
                                                      sourceIsDirectory: item.kind == .directory, destinationIsDirectory: destination.kind == .directory,
                                                      canKeepBoth: true), with: resolver)
            try validateLocation()
            try requireDirectory(sourceParent); try requireDirectory(parent)
            try requireRemoteSnapshot(item, at: source); try requireRemoteSnapshot(destination, at: target)
            if choice == .skip { skipped += 1; return }
            if choice == .merge {
                try requireDirectory(source); try requireDirectory(target)
                for child in try readDirectory(source) {
                    try requireDirectory(source); try requireDirectory(target)
                    try relocateResolving(RemoteFile.join(source, child.name), RemoteFile.join(target, child.name), copying: copying,
                                          depth: depth + 1, bytes: &bytes, skipped: &skipped, resolver: resolver,
                                          progress: progress, validateLocation: validateLocation)
                }
                if !copying {
                    try requireDirectory(source)
                    // 跳过及外部新增内容留在源目录；只用 RMDIR 删除已空目录，绝不递归清源。
                    if try readDirectory(source).isEmpty {
                        var body = SFTPWriter(); body.text(source)
                        _ = try request(15, body, expecting: 101)
                    }
                }
                return
            }
            if choice == .keepBoth {
                var index = 2
                repeat {
                    target = RemoteFile.join(parent, copyName(item.name, directory: item.kind == .directory, index: index))
                    index += 1
                } while try remoteItem(target) != nil
                existing = nil
            }
        }
        if copying {
            let temporary = RemoteFile.join(parent, ".nc2shell-copy-\(UUID().uuidString)")
            do {
                try copyRemoteTree(source, temporary, depth: depth, total: &bytes, progress: progress)
                try validateLocation(); try requireDirectory(parent); try requireDirectory(sourceParent)
                try requireRemoteSnapshot(item, at: source); try requireRemoteSnapshot(existing, at: target)
                if existing != nil { try replaceRemote(temporary, target) }
                else { try renamePath(temporary, to: target) }
            } catch {
                throw SFTPError.message("\(error.localizedDescription)\n未完成内容可能保留在：\(temporary)")
            }
        } else {
            let movedBytes = try inspectRemoteTree(source, depth: depth)
            try validateLocation(); try requireDirectory(parent); try requireDirectory(sourceParent)
            try requireRemoteSnapshot(item, at: source); try requireRemoteSnapshot(existing, at: target)
            if existing != nil { try replaceRemote(source, target) }
            else { try renamePath(source, to: target) }
            bytes += movedBytes; progress(bytes)
        }
    }

    private func copyRemoteTree(_ source: String, _ target: String, depth: Int, total: inout UInt64, progress: Progress) throws {
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        try requireDirectory((source as NSString).deletingLastPathComponent)
        try requireDirectory((target as NSString).deletingLastPathComponent)
        let item = try stat(source)
        try requireTransferable(item, at: source)
        if item.kind == .directory {
            try requireDirectory(source)
            var body = SFTPWriter(); body.text(target); body.uint32(0)
            _ = try request(14, body, expecting: 101)
            for child in try readDirectory(source) {
                try copyRemoteTree(RemoteFile.join(source, child.name), RemoteFile.join(target, child.name), depth: depth + 1, total: &total, progress: progress)
            }
        } else {
            var body = SFTPWriter(); body.text(source); body.uint32(1); body.uint32(0)
            var response = try request(3, body, expecting: 102)
            let readHandle = try response.string()
            defer { try? close(readHandle) }
            body = SFTPWriter(); body.text(target); body.uint32(2 | 8 | 32); body.uint32(0)
            response = try request(3, body, expecting: 102)
            let writeHandle = try response.string()
            var closed = false
            defer { if !closed { try? close(writeHandle) } }
            var pending: [(offset: UInt64, data: Data)] = []
            try readPayload(readHandle, limit: item.hasSize ? item.size : nil) { offset, data in
                pending.append((offset, data))
                if pending.count >= min(payloadWindow(.upload), payloadWindow(.download)) {
                    try writePayload(pending, handle: writeHandle) { _, data in total += UInt64(data.count); progress(total) }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty {
                try writePayload(pending, handle: writeHandle) { _, data in total += UInt64(data.count); progress(total) }
            }
            try close(writeHandle); closed = true
        }
        try requireDirectory((source as NSString).deletingLastPathComponent)
        try requireRemoteSnapshot(item, at: source)
    }

    private func uploadResolving(_ local: URL, _ requested: String, depth: Int, bytes: inout UInt64, skipped: inout Int,
                                 resolver: @escaping TransferConflictResolver, progress: Progress) throws {
        try checkCancellation()
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        try RemoteFile.validateName((requested as NSString).lastPathComponent)
        let source = try localSnapshot(local)
        try requireLocalTransferable(source, at: local)
        let parent = (requested as NSString).deletingLastPathComponent
        try requireDirectory(parent)
        var target = requested, existing = try remoteItem(target)
        if let item = existing {
            try requireTransferable(item, at: target)
            let choice = try resolve(TransferConflict(sourcePath: local.path, destinationPath: target,
                                                      sourceIsDirectory: source.isDirectory, destinationIsDirectory: item.kind == .directory,
                                                      canKeepBoth: true), with: resolver)
            try requireDirectory(parent)
            try requireRemoteSnapshot(item, at: target)
            if choice == .skip { skipped += 1; return }
            if choice == .merge {
                try requireDirectory(target)
                for entry in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try RemoteFile.validateName(entry.lastPathComponent)
                    try uploadResolving(entry, RemoteFile.join(target, entry.lastPathComponent), depth: depth + 1,
                                        bytes: &bytes, skipped: &skipped, resolver: resolver, progress: progress)
                }
                return
            }
            if choice == .keepBoth {
                var index = 2
                repeat {
                    target = RemoteFile.join(parent, copyName((requested as NSString).lastPathComponent, directory: source.isDirectory, index: index))
                    index += 1
                } while try remoteItem(target) != nil
                existing = nil
            }
        }
        let temporary = RemoteFile.join(parent, ".nc2shell-upload-\(UUID().uuidString)")
        do {
            try uploadTree(local, temporary, depth: depth, total: &bytes, progress: progress)
            try requireDirectory(parent)
            try requireRemoteSnapshot(existing, at: target)
            if existing != nil { try replaceRemote(temporary, target) }
            else { try renamePath(temporary, to: target) }
        } catch {
            throw SFTPError.message("\(error.localizedDescription)\n未完成内容可能保留在：\(temporary)")
        }
    }

    private func replaceRemote(_ temporary: String, _ target: String) throws {
        let parent = (target as NSString).deletingLastPathComponent
        let backup = RemoteFile.join(parent, ".nc2shell-backup-\(UUID().uuidString)")
        try requireMissing(backup)
        var installed = false
        do {
            // v3 服务器不必支持 posix-rename；新内容完整后才移动旧目标，绝不先删旧内容。
            try renamePath(target, to: backup)
            try renamePath(temporary, to: target)
            installed = true
            try deleteTree(backup, depth: 0)
        } catch {
            var restored = false
            if !installed {
                // 响应丢失时目标可能已经就位，只在目标仍缺失时尝试恢复旧内容。
                do {
                    try requireDirectory(parent)
                    if try remoteItem(target) == nil, try remoteItem(backup) != nil {
                        try renamePath(backup, to: target)
                        restored = true
                    }
                } catch { /* 取消或断线后保留备份，向用户报告精确位置。 */ }
            }
            let state = restored ? "已恢复原目标。" : (installed ? "新内容已就位，但旧内容备份清理未完成。" : "替换结果需要刷新确认，原内容可能位于备份中。")
            throw SFTPError.message("\(error.localizedDescription)\n\(state)\n目标：\(target)\n备份：\(backup)")
        }
    }

    private struct LocalSnapshot: Equatable {
        let type: FileAttributeType
        let size: UInt64
        let inode: UInt64
        let modified: Date?
        var isDirectory: Bool { type == .typeDirectory }
    }

    private func localSnapshot(_ url: URL) throws -> LocalSnapshot {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return LocalSnapshot(type: attrs[.type] as? FileAttributeType ?? .typeUnknown,
                             size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                             inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                             modified: attrs[.modificationDate] as? Date)
    }

    private func localItem(_ url: URL) throws -> LocalSnapshot? {
        do { return try localSnapshot(url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    private func requireLocalTransferable(_ item: LocalSnapshot, at url: URL) throws {
        guard item.type == .typeRegular || item.isDirectory else {
            throw SFTPError.message("暂不传输或覆盖符号链接及特殊文件：\(url.path)")
        }
    }

    private func requireLocalSnapshot(_ snapshot: LocalSnapshot?, at url: URL) throws {
        guard try localItem(url) == snapshot else {
            throw SFTPError.message("本地目标在等待或传输期间已变化：\(url.path)")
        }
    }

    private func downloadResolving(_ remote: String, _ requested: URL, depth: Int, bytes: inout UInt64, skipped: inout Int,
                                   canKeepBoth: Bool, resolver: @escaping TransferConflictResolver, progress: Progress) throws {
        try checkCancellation()
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        try requireDirectory((remote as NSString).deletingLastPathComponent)
        let source = try stat(remote)
        try requireTransferable(source, at: remote)
        let manager = FileManager.default, parent = requested.deletingLastPathComponent()
        let canonicalParent = parent.resolvingSymlinksInPath()
        var target = requested, existing = try localItem(target)
        if let item = existing {
            try requireLocalTransferable(item, at: target)
            let choice = try resolve(TransferConflict(sourcePath: remote, destinationPath: target.path,
                                                      sourceIsDirectory: source.kind == .directory, destinationIsDirectory: item.isDirectory,
                                                      canKeepBoth: canKeepBoth), with: resolver)
            try requireLocalSnapshot(item, at: target)
            guard parent.resolvingSymlinksInPath() == canonicalParent else { throw SFTPError.message("本地目标目录已变化。") }
            if choice == .skip { skipped += 1; return }
            if choice == .merge {
                try requireDirectory(remote)
                for entry in try readDirectory(remote) {
                    // 上一项的冲突弹窗期间父目录也可能被替换为链接。
                    guard try localSnapshot(target).isDirectory, parent.resolvingSymlinksInPath() == canonicalParent,
                          target.resolvingSymlinksInPath() == canonicalParent.appendingPathComponent(target.lastPathComponent) else {
                        throw SFTPError.message("本地合并目录已变化：\(target.path)")
                    }
                    try downloadResolving(RemoteFile.join(remote, entry.name), target.appendingPathComponent(entry.name), depth: depth + 1,
                                          bytes: &bytes, skipped: &skipped, canKeepBoth: true, resolver: resolver, progress: progress)
                }
                return
            }
            if choice == .keepBoth {
                var index = 2
                repeat {
                    target = parent.appendingPathComponent(copyName(requested.lastPathComponent, directory: source.kind == .directory, index: index))
                    index += 1
                } while try localItem(target) != nil
                existing = nil
            }
        }
        let staging = parent.appendingPathComponent(".nc2shell-download-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("content")
        try downloadTree(remote, temporary, depth: depth, total: &bytes, progress: progress)
        try checkCancellation()
        guard parent.resolvingSymlinksInPath() == canonicalParent else { throw SFTPError.message("本地目标目录已变化。") }
        try requireLocalSnapshot(existing, at: target)
        if existing != nil { try replaceLocal(temporary, target) }
        else { try manager.moveItem(at: temporary, to: target) }
    }

    private func replaceLocal(_ temporary: URL, _ target: URL) throws {
        let manager = FileManager.default
        let backup = target.deletingLastPathComponent().appendingPathComponent(".nc2shell-backup-\(UUID().uuidString)")
        var backedUp = false, installed = false
        do {
            try manager.moveItem(at: target, to: backup)
            backedUp = true
            try checkCancellation()
            try manager.moveItem(at: temporary, to: target)
            installed = true
            try manager.removeItem(at: backup)
        } catch {
            var restored = false
            if backedUp && !installed {
                do {
                    if try localItem(target) == nil {
                        try manager.moveItem(at: backup, to: target)
                        restored = true
                    }
                } catch { /* 备份不随暂存目录清理，失败时仍可手动恢复。 */ }
            }
            let state = restored ? "已恢复原目标。" : (installed ? "新内容已就位，但旧内容备份清理未完成。" : "替换未完成，请检查原目标及备份。")
            throw SFTPError.message("\(error.localizedDescription)\n\(state)\n目标：\(target.path)\n备份：\(backup.path)")
        }
    }
}


// 检查点分支独立于原有无状态 API，恢复时只写本任务的隐藏暂存内容。
extension SFTPClient {
    typealias ResumeSnapshot = TransferCheckpoint.Snapshot
    typealias ResumeRecord = TransferCheckpoint.Record

    enum ResumeHandle { case local(FileHandle), remote(Data) }

    func resumeParent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    func requireResumeParent(_ path: String, remote: Bool) throws {
        let parent = resumeParent(path)
        if remote { try requireDirectory(parent) }
        else {
            let url = URL(fileURLWithPath: parent)
            guard url.resolvingSymlinksInPath() == url, try localSnapshot(url).isDirectory else {
                throw SFTPError.message("本地目录已变化或包含符号链接：\(parent)")
            }
        }
    }

    func resumeNames(_ path: String, remote: Bool) throws -> [String] {
        if remote { try requireDirectory(path); return try readDirectory(path).map(\.name).sorted() }
        let url = URL(fileURLWithPath: path)
        guard try localSnapshot(url).isDirectory, url.resolvingSymlinksInPath() == url else {
            throw SFTPError.message("本地目录已变化：\(path)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        for name in names { try RemoteFile.validateName(name) }
        return names
    }

    func resumeMetadata(_ path: String, remote: Bool, includePermissions: Bool = false) throws -> ResumeSnapshot? {
        try requireResumeParent(path, remote: remote)
        if remote {
            guard let item = try remoteItem(path) else { return nil }
            try requireTransferable(item, at: path)
            return ResumeSnapshot(directory: item.kind == .directory, size: item.kind == .file && item.hasSize ? item.size : nil,
                                  modified: item.modifiedTime.map(Double.init), inode: nil, digest: nil, children: nil,
                                  mode: includePermissions ? item.mode & 0o7777 : nil)
        }
        guard let item = try localItem(URL(fileURLWithPath: path)) else { return nil }
        try requireLocalTransferable(item, at: URL(fileURLWithPath: path))
        var mode: UInt32?
        if includePermissions {
            var info = Darwin.stat()
            guard lstat(path, &info) == 0, UInt64(info.st_ino) == item.inode,
                  info.st_mode & S_IFMT == (item.isDirectory ? S_IFDIR : S_IFREG) else { throw SFTPError.message("读取属性时本地项目已变化：\(path)") }
            mode = UInt32(info.st_mode) & 0o7777
        }
        return ResumeSnapshot(directory: item.isDirectory, size: item.isDirectory ? nil : item.size,
                              modified: item.modified?.timeIntervalSince1970, inode: item.inode, digest: nil, children: nil, mode: mode)
    }

    func resumeOpen(_ path: String, remote: Bool, writing: Bool, create: Bool = false,
                    identity: TransferCheckpoint.LocalIdentity? = nil) throws -> ResumeHandle {
        try requireResumeParent(path, remote: remote)
        if remote {
            var body = SFTPWriter(); body.text(path); body.uint32(writing ? (create ? 2 | 8 | 32 : 2) : 1); body.uint32(0)
            var response = try request(3, body, expecting: 102)
            return .remote(try response.string())
        }
        let fd = Darwin.open(path, (writing ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | (create ? O_CREAT | O_EXCL : 0), 0o600)
        guard fd >= 0 else { throw SFTPError.message("无法\(writing ? "写入" : "读取")续传文件：\(path)") }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(fd); throw SFTPError.message("续传路径不是普通文件：\(path)")
        }
        if let identity {
            do {
                guard try resumeLocalIdentity(info) == identity else { throw SFTPError.message("本地续传暂存文件身份已变化：\(path)") }
            } catch { _ = Darwin.close(fd); throw error }
        }
        return .local(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    func resumeLocalIdentity(_ info: Darwin.stat) throws -> TransferCheckpoint.LocalIdentity {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw SFTPError.message("本地续传暂存文件已变化或存在硬链接，已停止写入。")
        }
        return TransferCheckpoint.LocalIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    func resumeLocalIdentity(_ file: FileHandle) throws -> TransferCheckpoint.LocalIdentity {
        var info = Darwin.stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { throw SFTPError.message("无法校验本地续传文件句柄。") }
        return try resumeLocalIdentity(info)
    }

    func requireLocalTemporary(_ path: String, identity: TransferCheckpoint.LocalIdentity) throws {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0, try resumeLocalIdentity(info) == identity else {
            throw SFTPError.message("本地续传暂存路径或文件身份已变化：\(path)")
        }
    }

    func resumeRead(_ handle: ResumeHandle, offset: UInt64, count: Int = 32768) throws -> Data {
        try waitUntilResumed()
        switch handle {
        case .local(let file): try file.seek(toOffset: offset); return try file.read(upToCount: count) ?? Data()
        case .remote(let handle):
            try acquirePayload(count, direction: .download)
            var body = SFTPWriter(); body.string(handle); body.uint64(offset); body.uint32(UInt32(count))
            var reply: SFTPReader
            do { reply = try request(5, body, expecting: 103) }
            catch SFTPError.status(1, _) { bandwidthLimiter?.refundUnusedReadBytes(count); return Data() }
            catch { bandwidthLimiter?.refundUnusedReadBytes(count); throw error }
            let data = try reply.string()
            guard !data.isEmpty, data.count <= count else { throw SFTPError.message("续传数据长度无效。") }
            bandwidthLimiter?.refundUnusedReadBytes(count - data.count)
            return data
        }
    }

    func resumeReadExactly(_ handle: ResumeHandle, offset: UInt64, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let part = try resumeRead(handle, offset: offset + UInt64(result.count), count: count - result.count)
            guard !part.isEmpty else { throw SFTPError.message("续传校验片段长度已变化。") }
            result.append(part)
        }
        return result
    }

    func resumeWrite(_ data: Data, to file: FileHandle, offset: UInt64,
                     localPath: String, identity: TransferCheckpoint.LocalIdentity?) throws {
        try waitUntilResumed()
        guard let identity, try resumeLocalIdentity(file) == identity else { throw SFTPError.message("本地续传暂存文件身份已变化。") }
        try requireLocalTemporary(localPath, identity: identity)
        try file.seek(toOffset: offset); try file.write(contentsOf: data); try file.synchronize()
    }

    func resumeClose(_ handle: ResumeHandle) throws {
        switch handle { case .local(let file): try file.close(); case .remote(let data): try close(data) }
    }

    func resumeHash(_ path: String, remote: Bool, limit: UInt64? = nil) throws -> (SHA256, UInt64) {
        let handle = try resumeOpen(path, remote: remote, writing: false)
        defer { try? resumeClose(handle) }
        var hash = SHA256(), offset: UInt64 = 0
        if case .remote(let handle) = handle {
            offset = try readPayload(handle, limit: limit) { _, data in hash.update(data: data) }
        } else {
            while limit == nil || offset < limit! {
                let count = Int(min(UInt64(32768), limit.map { $0 - offset } ?? 32768))
                let data = try resumeRead(handle, offset: offset, count: count)
                if data.isEmpty { break }
                hash.update(data: data); offset += UInt64(data.count)
            }
        }
        if let limit, offset != limit { throw SFTPError.message("续传片段长度已变化：\(path)") }
        return (hash, offset)
    }

    func resumeDigest(_ hash: SHA256) -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }

    func resumeSnapshot(_ path: String, remote: Bool, content: Bool, depth: Int = 0, includePermissions: Bool = false) throws -> ResumeSnapshot? {
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        guard var item = try resumeMetadata(path, remote: remote, includePermissions: includePermissions) else { return nil }
        let before = item
        if item.directory {
            let names = try resumeNames(path, remote: remote)
            var children: [String: ResumeSnapshot] = [:]
            for name in names {
                guard let child = try resumeSnapshot(RemoteFile.join(path, name), remote: remote, content: content, depth: depth + 1, includePermissions: includePermissions) else {
                    throw SFTPError.message("目录成员已变化：\(path)")
                }
                children[name] = child
            }
            guard try resumeNames(path, remote: remote) == names else { throw SFTPError.message("目录成员已变化：\(path)") }
            item.children = children
        } else if content { item.digest = try resumeDigest(resumeHash(path, remote: remote).0) }
        guard try resumeMetadata(path, remote: remote, includePermissions: includePermissions) == before else { throw SFTPError.message("校验期间文件已变化：\(path)") }
        return item
    }

    func requireResumeSnapshot(_ expected: ResumeSnapshot?, at path: String, remote: Bool, content: Bool) throws {
        guard try resumeSnapshot(path, remote: remote, content: content, includePermissions: expected?.mode != nil) == expected else {
            throw SFTPError.message("来源、目标或已完成内容已变化，不能安全续传：\(path)")
        }
    }

    func transferResuming(source: String, requested: String, upload: Bool, canKeepBoth: Bool,
                          checkpoint: TransferCheckpoint, resolver: @escaping TransferConflictResolver,
                          progress: Progress) throws -> TransferResult {
        try checkpoint.begin(); defer { checkpoint.end() }
        try checkpoint.requireResumable()
        // 本地 /var 等系统别名在入口规范化；叶子仍由 LSTAT/O_NOFOLLOW 检查，不能跟随链接文件。
        func canonicalLocal(_ path: String) -> String {
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        let originalSource = source, originalTarget = requested
        let source = upload ? canonicalLocal(source) : source
        let requested = upload ? requested : canonicalLocal(requested)
        try checkpoint.bindRoot(source: originalSource, requested: originalTarget, upload: upload, resolvedSource: source, resolvedTarget: requested)
        var bytes: UInt64 = 0, skipped = 0
        do {
            let key = TransferCheckpoint.key(upload: upload, source: source, requested: requested)
            if checkpoint.metadataProgress(for: key) != nil, let completed = checkpoint.record(key) {
                guard completed.canKeepBoth == canKeepBoth, completed.sourceSnapshot.resumable else {
                    throw SFTPError.message("来源缺少大小/修改时间，或目标改名策略已变化，不能安全恢复属性：\(source)")
                }
                try requireResumeSnapshot(completed.sourceSnapshot, at: source, remote: !upload, content: upload)
                try finishTransferMetadata(completed, checkpoint: checkpoint)
                bytes = completed.bytes; skipped = completed.skipped
                checkpoint.onReusedBytes(bytes); progress(bytes)
            } else {
                try resumeNode(source: source, requested: requested, upload: upload, canKeepBoth: canKeepBoth,
                               checkpoint: checkpoint, resolver: resolver, bytes: &bytes, skipped: &skipped, progress: progress, depth: 0)
                if checkpoint.attributes.isEnabled, let completed = checkpoint.record(key), completed.phase == "complete" {
                    try finishTransferMetadata(completed, checkpoint: checkpoint)
                }
            }
        } catch {
            if let record = checkpoint.record(TransferCheckpoint.key(upload: upload, source: source, requested: requested)),
               record.phase != "complete",
               !error.localizedDescription.contains(record.temporary) {
                throw SFTPError.message("\(error.localizedDescription)\n目标：\(record.target)\n暂存：\(record.temporary)\n备份：\(record.backup)")
            }
            throw error
        }
        return TransferResult(bytes: bytes, skippedCount: skipped)
    }

    func resumeNode(source: String, requested: String, upload: Bool, canKeepBoth: Bool,
                    checkpoint: TransferCheckpoint, resolver: @escaping TransferConflictResolver,
                    bytes: inout UInt64, skipped: inout Int, progress: Progress, depth: Int) throws {
        try checkCancellation()
        guard depth < 64 else { throw SFTPError.message("文件夹嵌套超过 64 层。") }
        try RemoteFile.validateName((requested as NSString).lastPathComponent)
        try requireResumeParent(source, remote: !upload); try requireResumeParent(requested, remote: upload)
        let key = TransferCheckpoint.key(upload: upload, source: source, requested: requested)
        guard let currentSource = try resumeSnapshot(source, remote: !upload, content: upload, depth: depth, includePermissions: checkpoint.attributes.isEnabled) else {
            throw SFTPError.message("续传来源不存在：\(source)")
        }
        var record: ResumeRecord
        if let saved = checkpoint.record(key) {
            record = saved
            guard saved.canKeepBoth == canKeepBoth, saved.sourceSnapshot.resumable,
                  saved.sourceSnapshot == currentSource else { throw SFTPError.message("来源已变化或缺少大小/修改时间，不能安全续传：\(source)") }
            if saved.target != requested {
                let name = (requested as NSString).lastPathComponent
                guard (2...100_001).contains(where: { RemoteFile.join(resumeParent(requested), copyName(name, directory: currentSource.directory, index: $0)) == saved.target }) else {
                    throw SFTPError.message("检查点目标名称无效。")
                }
            }
        } else {
            let previous = try resumeSnapshot(requested, remote: upload, content: true, depth: depth, includePermissions: checkpoint.attributes.isEnabled)
            var target = requested, choice = "new", existing = previous
            if let previous {
                let selected = try resolve(TransferConflict(sourcePath: source, destinationPath: requested, sourceIsDirectory: currentSource.directory,
                                                            destinationIsDirectory: previous.directory, canKeepBoth: canKeepBoth), with: resolver)
                try requireResumeSnapshot(currentSource, at: source, remote: !upload, content: upload)
                try requireResumeSnapshot(previous, at: requested, remote: upload, content: true)
                switch selected {
                case .replace: choice = "replace"
                case .skip: choice = "skip"
                case .merge: choice = "merge"
                case .keepBoth:
                    choice = "keepBoth"
                    var index = 2
                    repeat {
                        target = RemoteFile.join(resumeParent(requested), copyName((requested as NSString).lastPathComponent, directory: currentSource.directory, index: index))
                        index += 1
                    } while try resumeMetadata(target, remote: upload) != nil
                    existing = nil
                case .cancel: throw SFTPError.message("传输已取消。")
                }
            }
            record = ResumeRecord(id: checkpoint.identifier(for: key), source: source, requested: requested, upload: upload, canKeepBoth: canKeepBoth,
                                  sourceSnapshot: currentSource, target: target, previous: existing, choice: choice)
            if choice == "skip" { record.phase = "skipped"; record.skipped = 1 }
            if choice == "merge" { record.phase = "merging" }
            try checkpoint.save(record, key: key)
        }
        do {
            if record.phase == "installing" {
                throw SFTPError.message("上次安装结果不明，已停止续传，请先检查目标、暂存及备份。")
            }
            if record.phase == "complete" {
                try requireResumeSnapshot(record.result, at: record.target, remote: upload, content: true)
                bytes += record.bytes; skipped += record.skipped
                checkpoint.onReusedBytes(record.bytes); progress(bytes); return
            }
            if record.phase == "skipped" {
                try requireResumeSnapshot(record.previous, at: record.target, remote: upload, content: true)
                skipped += 1; return
            }
            let initialBytes = bytes, initialSkipped = skipped
            if record.phase == "merging" {
                guard let current = try resumeMetadata(record.target, remote: upload), current.directory,
                      upload || current.inode == record.previous?.inode else { throw SFTPError.message("合并目标目录已变化。") }
                var allowed = Set((record.previous?.children ?? [:]).keys).union((currentSource.children ?? [:]).keys)
                for child in checkpoint.records where resumeParent(child.requested) == record.target {
                    allowed.formUnion([child.target, child.temporary, child.backup].map { ($0 as NSString).lastPathComponent })
                }
                guard Set(try resumeNames(record.target, remote: upload)).isSubset(of: allowed) else { throw SFTPError.message("合并目标目录成员已变化。") }
                // 非来源成员不会被本任务修改；恢复前必须仍保持原内容。
                for (name, old) in record.previous?.children ?? [:] where currentSource.children?[name] == nil {
                    try requireResumeSnapshot(old, at: RemoteFile.join(record.target, name), remote: upload, content: true)
                }
                for name in (currentSource.children ?? [:]).keys.sorted() {
                    let childSource = RemoteFile.join(source, name), childTarget = RemoteFile.join(record.target, name)
                    let childKey = TransferCheckpoint.key(upload: upload, source: childSource, requested: childTarget)
                    if checkpoint.record(childKey) == nil {
                        try requireResumeSnapshot(record.previous?.children?[name], at: childTarget, remote: upload, content: true)
                    }
                    try resumeNode(source: childSource, requested: childTarget, upload: upload, canKeepBoth: true,
                                   checkpoint: checkpoint, resolver: resolver, bytes: &bytes, skipped: &skipped, progress: progress, depth: depth + 1)
                }
            } else {
                try requireResumeSnapshot(record.previous, at: record.target, remote: upload, content: true)
                if record.phase == "prepared" {
                    guard try resumeMetadata(record.temporary, remote: upload) == nil else {
                        throw SFTPError.message("暂存创建结果不明，不能覆盖现有内容。")
                    }
                    if currentSource.directory {
                        if upload { var body = SFTPWriter(); body.text(record.temporary); body.uint32(0); _ = try request(14, body, expecting: 101) }
                        else if mkdir(record.temporary, 0o700) != 0 { throw SFTPError.message("无法创建续传暂存目录。") }
                    } else {
                        let created = try resumeOpen(record.temporary, remote: upload, writing: true, create: true)
                        defer { try? resumeClose(created) }
                        if case .local(let file) = created { record.localTemporaryIdentity = try resumeLocalIdentity(file) }
                    }
                    record.phase = "copying"; try checkpoint.save(record, key: key)
                }
                if currentSource.directory {
                    let expectedNames = Set((currentSource.children ?? [:]).keys)
                    let childTemporaryNames = checkpoint.records.filter { resumeParent($0.temporary) == record.temporary }.map { ($0.temporary as NSString).lastPathComponent }
                    let allowed = expectedNames.union(childTemporaryNames)
                    guard Set(try resumeNames(record.temporary, remote: upload)).isSubset(of: allowed) else { throw SFTPError.message("续传暂存目录成员已变化。") }
                    for name in expectedNames.sorted() {
                        let childSource = RemoteFile.join(source, name), childTarget = RemoteFile.join(record.temporary, name)
                        if checkpoint.record(TransferCheckpoint.key(upload: upload, source: childSource, requested: childTarget)) == nil,
                           try resumeMetadata(childTarget, remote: upload) != nil {
                            throw SFTPError.message("续传暂存目录出现未经确认的内容：\(childTarget)")
                        }
                        try resumeNode(source: childSource, requested: childTarget, upload: upload, canKeepBoth: true,
                                       checkpoint: checkpoint, resolver: resolver, bytes: &bytes, skipped: &skipped, progress: progress, depth: depth + 1)
                    }
                } else {
                    try resumeFile(&record, key: key, checkpoint: checkpoint, bytes: &bytes, progress: progress)
                }
                try requireResumeSnapshot(currentSource, at: source, remote: !upload, content: upload)
                try requireResumeSnapshot(record.previous, at: record.target, remote: upload, content: true)
                if let identity = record.localTemporaryIdentity { try requireLocalTemporary(record.temporary, identity: identity) }
                try checkCancellation()
                // 先持久化安装意图，任何 rename 的响应丢失都不能在重试时盲目覆盖。
                record.phase = "installing"; try checkpoint.save(record, key: key)
                do {
                    if record.previous != nil {
                        guard try resumeMetadata(record.backup, remote: upload) == nil else { throw SFTPError.message("备份路径已存在。") }
                        try resumeMove(record.target, to: record.backup, remote: upload)
                    }
                    try resumeMove(record.temporary, to: record.target, remote: upload)
                    if record.previous != nil {
                        if upload { try deleteTree(record.backup, depth: 0) }
                        else { try FileManager.default.removeItem(atPath: record.backup) }
                    }
                } catch {
                    var restored = false
                    if record.previous != nil {
                        do {
                            try checkCancellation()
                            if try resumeMetadata(record.target, remote: upload) == nil {
                                try requireResumeSnapshot(record.previous, at: record.backup, remote: upload, content: true)
                                try resumeMove(record.backup, to: record.target, remote: upload)
                                restored = true
                                record.phase = "copying"; try checkpoint.save(record, key: key)
                            }
                        } catch { /* 无法确认时保留原记录与备份，禁止重试安装。 */ }
                    }
                    throw SFTPError.message("\(error.localizedDescription)\n\(restored ? "已恢复原目标。" : "安装结果需要检查确认。")")
                }
            }
            try requireResumeSnapshot(currentSource, at: source, remote: !upload, content: upload)
            if upload && record.choice != "merge" {
                guard let installed = try resumeSnapshot(record.target, remote: true, content: false, depth: depth, includePermissions: checkpoint.attributes.isEnabled) else {
                    throw SFTPError.message("上传目标在安装后已变化。")
                }
                // 已确认的 WRITE 与来源摘要足以记录本次结果；日后复用完成项时再读远端校验。
                record.result = try resumeSentSnapshot(currentSource, installed: installed)
            } else {
                record.result = try resumeSnapshot(record.target, remote: upload, content: true, depth: depth, includePermissions: checkpoint.attributes.isEnabled)
            }
            record.bytes = bytes - initialBytes; record.skipped = skipped - initialSkipped
            record.phase = "complete"; try checkpoint.save(record, key: key)
        } catch {
            throw SFTPError.message("\(error.localizedDescription)\n目标：\(record.target)\n暂存：\(record.temporary)\n备份：\(record.backup)")
        }
    }

    func resumeMove(_ source: String, to target: String, remote: Bool) throws {
        try waitUntilResumed()
        try requireResumeParent(source, remote: remote); try requireResumeParent(target, remote: remote)
        if remote { try renamePath(source, to: target) }
        else { try FileManager.default.moveItem(atPath: source, toPath: target) }
    }

    func resumeSentSnapshot(_ source: ResumeSnapshot, installed: ResumeSnapshot) throws -> ResumeSnapshot {
        guard source.directory == installed.directory else { throw SFTPError.message("上传目标类型已变化。") }
        var result = installed
        if source.directory {
            guard Set((source.children ?? [:]).keys) == Set((installed.children ?? [:]).keys) else {
                throw SFTPError.message("上传目标目录成员已变化。")
            }
            var children: [String: ResumeSnapshot] = [:]
            for (name, child) in source.children ?? [:] {
                guard let actual = installed.children?[name] else { throw SFTPError.message("上传目标目录成员已变化。") }
                children[name] = try resumeSentSnapshot(child, installed: actual)
            }
            result.children = children
        } else {
            guard source.digest != nil, installed.size == nil || source.size == installed.size else {
                throw SFTPError.message("上传目标长度已变化。")
            }
            result.digest = source.digest
        }
        return result
    }

    func resumeFile(_ record: inout ResumeRecord, key: String, checkpoint: TransferCheckpoint, bytes: inout UInt64, progress: Progress) throws {
        guard let temporary = try resumeMetadata(record.temporary, remote: record.upload), !temporary.directory,
              let length = temporary.size, length >= record.offset,
              record.sourceSnapshot.size.map({ length <= $0 }) ?? true else { throw SFTPError.message("续传暂存文件大小或类型已变化。") }
        if !record.upload {
            guard let identity = record.localTemporaryIdentity else { throw SFTPError.message("检查点缺少本地暂存文件身份，不能安全续传。") }
            try requireLocalTemporary(record.temporary, identity: identity)
        }
        var hash = SHA256()
        var confirmedLength = length
        if length > 0 {
            if record.upload {
                hash = try resumeHash(record.temporary, remote: true, limit: length).0
                let original = try resumeHash(record.source, remote: false, limit: length)
                guard resumeDigest(hash) == resumeDigest(original.0) else { throw SFTPError.message("远端续传片段内容校验失败，已变化。") }
                // 窗口内已经写到远端但未保存检查点的尾部不算复用，仍从连续确认偏移重发。
                confirmedLength = record.offset
                hash = try resumeHash(record.source, remote: false, limit: confirmedLength).0
            } else {
                // 每次 WRITE 后立即保存，未记录尾部最多是一块；必须独立核对，不能凭长度追加。
                guard length - record.offset <= 32768 else { throw SFTPError.message("本地续传片段含过多未确认内容。") }
                hash = try resumeHash(record.temporary, remote: false, limit: record.offset).0
                guard (record.offset == 0 && record.prefixDigest == nil) || resumeDigest(hash) == record.prefixDigest else {
                    throw SFTPError.message("本地续传片段内容校验失败，已变化。")
                }
                let source = try resumeOpen(record.source, remote: true, writing: false)
                let local = try resumeOpen(record.temporary, remote: false, writing: false, identity: record.localTemporaryIdentity)
                defer { try? resumeClose(source); try? resumeClose(local) }
                if length > record.offset {
                    let count = Int(length - record.offset)
                    let tail = try resumeReadExactly(local, offset: record.offset, count: count)
                    guard try resumeReadExactly(source, offset: record.offset, count: count) == tail else {
                        throw SFTPError.message("本地未确认尾部与远端来源不符，不能安全续传。")
                    }
                    hash.update(data: tail)
                }
                // 只读取首尾边界块，避免为了恢复下载再次读取全部远端数据。
                for offset in Set([UInt64(0), length > 32768 ? length - 32768 : 0]) {
                    let count = Int(min(32768, length - offset))
                    guard try resumeReadExactly(source, offset: offset, count: count) == resumeReadExactly(local, offset: offset, count: count) else {
                        throw SFTPError.message("远端来源边界内容已变化。")
                    }
                }
                if let identity = record.localTemporaryIdentity { try requireLocalTemporary(record.temporary, identity: identity) }
            }
            record.offset = confirmedLength; record.prefixDigest = resumeDigest(hash); try checkpoint.save(record, key: key)
            bytes += confirmedLength; checkpoint.onReusedBytes(confirmedLength); progress(bytes)
        }
        let source = try resumeOpen(record.source, remote: !record.upload, writing: false)
        defer { try? resumeClose(source) }
        let target = try resumeOpen(record.temporary, remote: record.upload, writing: true, identity: record.localTemporaryIdentity)
        var closed = false
        defer { if !closed { try? resumeClose(target) } }
        var offset = confirmedLength
        func confirmed(_ start: UInt64, _ data: Data) throws {
            hash.update(data: data); offset = start + UInt64(data.count)
            guard record.sourceSnapshot.size.map({ offset <= $0 }) ?? true else { throw SFTPError.message("来源大小已变化。") }
            record.offset = offset; record.prefixDigest = resumeDigest(hash)
            try checkpoint.save(record, key: key)
            bytes += UInt64(data.count); progress(bytes)
        }
        switch (source, target) {
        case (.local(let file), .remote(let handle)):
            try uploadPayload(file, handle: handle, offset: offset, confirmed: confirmed)
        case (.remote(let handle), .local(let file)):
            try readPayload(handle, offset: offset, limit: record.sourceSnapshot.size) { start, data in
                try resumeWrite(data, to: file, offset: start, localPath: record.temporary, identity: record.localTemporaryIdentity)
                try confirmed(start, data)
            }
        default: throw SFTPError.message("续传来源与目标类型无效。")
        }
        guard record.sourceSnapshot.size.map({ offset == $0 }) ?? true else { throw SFTPError.message("来源长度已变化。") }
        if record.upload, record.sourceSnapshot.digest != resumeDigest(hash) { throw SFTPError.message("上传过程中来源内容已变化。") }
        if let identity = record.localTemporaryIdentity { try requireLocalTemporary(record.temporary, identity: identity) }
        try resumeClose(target); closed = true
    }
}

private final class ConflictDecisionWait: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<TransferConflictChoice, Error>?
    private var task: Task<Void, Never>?

    func attach(_ task: Task<Void, Never>) {
        condition.lock()
        self.task = task
        let completed = result != nil
        condition.unlock()
        if completed { task.cancel() }
    }

    func finish(_ result: Result<TransferConflictChoice, Error>) {
        condition.lock()
        if self.result == nil { self.result = result; condition.signal() }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        if result == nil { result = .failure(SFTPError.message("传输已取消或连接已断开。")); condition.signal() }
        let pending = task
        condition.unlock()
        pending?.cancel()
    }

    func wait() throws -> TransferConflictChoice {
        condition.lock()
        while result == nil { condition.wait() }
        let value = result!
        task = nil
        condition.unlock()
        return try value.get()
    }
}
