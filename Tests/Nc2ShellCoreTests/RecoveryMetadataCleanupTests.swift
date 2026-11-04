import XCTest
import Darwin
@testable import Nc2ShellCore

final class RecoveryMetadataCleanupTests: XCTestCase {
    func testOrphanPreviewAndRemovalPreserveLockDirectoryAndUserFiles() throws {
        try fixture { store, task in
            let checkpoint = store.checkpointURL(for: task.id)
            try Data("retained checkpoint".utf8).write(to: checkpoint)
            XCTAssertTrue(try store.orphanedMetadata().isEmpty)
            try store.remove(task.id)
            let candidates = try store.orphanedMetadata()
            XCTAssertEqual(candidates.map(\.id), [task.id])
            XCTAssertEqual(candidates[0].bytes, 19)
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
            try store.removeOrphanedMetadata(expected: candidates[0])
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.deletingLastPathComponent().path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.appendingPathExtension("lock").path))
            XCTAssertTrue(try store.orphanedMetadata().isEmpty)
        }
    }

    func testPreviewChangesNewTaskAndCheckpointLocksPreventRemoval() throws {
        for change in ["content", "task", "checkpointLock", "metadataLock", "symlink"] {
            try fixture { store, task in
                let checkpoint = store.checkpointURL(for: task.id)
                try Data("before".utf8).write(to: checkpoint)
                try store.remove(task.id)
                let candidate = try XCTUnwrap(store.orphanedMetadata().first)
                var fd: Int32 = -1
                defer { if fd >= 0 { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) } }
                switch change {
                case "content": try Data("changed".utf8).write(to: checkpoint)
                case "task": try store.save(task)
                case "checkpointLock", "metadataLock":
                    let lock = change == "checkpointLock" ? checkpoint.appendingPathExtension("lock") : checkpoint.deletingLastPathComponent().appendingPathComponent("metadata.lock")
                    fd = Darwin.open(lock.path, O_RDWR | O_CREAT, 0o600); XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
                    if change == "metadataLock" { XCTAssertThrowsError(try store.save(task)); XCTAssertThrowsError(try store.remove(task.id)) }
                default:
                    let other = checkpoint.deletingLastPathComponent().appendingPathComponent("outside")
                    try Data("outside".utf8).write(to: other)
                    try FileManager.default.removeItem(at: checkpoint)
                    try FileManager.default.createSymbolicLink(at: checkpoint, withDestinationURL: other)
                }
                XCTAssertThrowsError(try store.removeOrphanedMetadata(expected: candidate), change)
                XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path), change)
            }
        }
    }

    func testAbandonMarkerCannotBeClearedByStaleWriter() throws {
        try fixture { store, task in
            try store.markCleanupStarted(task.id)
            XCTAssertNotNil(try store.load().first?.cleanupStartedAt)
            XCTAssertThrowsError(try store.save(task))
            XCTAssertNotNil(try store.load().first?.cleanupStartedAt)
        }
    }

    func testHardlinkedCheckpointLockIsRejected() throws {
        try fixture { store, task in
            let checkpoint = try TransferCheckpoint(fileURL: store.checkpointURL(for: task.id))
            let lock = checkpoint.fileURL.appendingPathExtension("lock")
            let outside = lock.deletingLastPathComponent().appendingPathComponent("other-lock")
            try Data().write(to: outside)
            try FileManager.default.linkItem(at: outside, to: lock)
            XCTAssertThrowsError(try checkpoint.begin())
        }
    }

    private func fixture(_ body: (TransferRecoveryStore, RecoverableTransfer) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("metadata-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root)
        let task = RecoverableTransfer(account: .init(profile: .init(name: "test", host: "example.test")), name: "test", direction: .upload,
                                      roots: [.init(localPath: "/local/file", remotePath: "/remote/file")])
        try store.save(task)
        try body(store, task)
    }
}
