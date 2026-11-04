import Foundation
import Darwin

/// 不删除锁文件，避免另一进程仍锁着旧 inode 时出现两把不同的锁。
final class RecoveryFileLock {
    private let descriptor: Int32

    init(_ url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.resolvingSymlinksInPath() == parent else { throw ProfileError("恢复资料目录包含符号链接：\(parent.path)") }
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProfileError("无法打开恢复资料锁：\(url.path)") }
        var opened = Darwin.stat(), named = Darwin.stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              opened.st_size == 0, flock(fd, LOCK_EX | LOCK_NB) == 0,
              lstat(url.path, &named) == 0, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            _ = Darwin.close(fd)
            throw ProfileError("恢复资料正在使用，或锁文件身份异常：\(url.path)")
        }
        descriptor = fd
    }

    deinit { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
}
