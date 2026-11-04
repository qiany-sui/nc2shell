import XCTest
@testable import Nc2ShellCore

final class TransferCleanupTests: XCTestCase {
    func testManifestCannotOverrideOriginalPartialFileDigest() throws {
        try fixture { task, checkpoint in
            var root = try bind(task, checkpoint)
            root.phase = "copying"; root.offset = 10; root.prefixDigest = "original"
            try save(root, checkpoint)
            let item = TransferCleanupPlan.Item(path: root.temporary, remote: true,
                                                snapshot: .init(directory: false, size: 10, modified: 2, digest: "replacement"), localDevice: nil)
            try checkpoint.markCleanupStarted(.init(taskID: task.id, items: [item]))
            XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task), "清单不能替换原记录已确认片段摘要")
        }
    }

    func testManifestCannotOverrideCompletedChildSnapshot() throws {
        try fixture { task, checkpoint in
            var root = try bind(task, checkpoint, directory: true)
            root = replacingSnapshot(root, directorySnapshot(["child": fileSnapshot])); root.phase = "copying"
            try save(root, checkpoint)
            var child = record(checkpoint, source: root.source + "/child", requested: root.temporary + "/child", snapshot: fileSnapshot)
            child.phase = "complete"; child.result = fileSnapshot
            try save(child, checkpoint)
            var replaced = fileSnapshot; replaced.digest = "replacement"
            let item = TransferCleanupPlan.Item(path: child.target, remote: true, snapshot: replaced, localDevice: nil)
            try checkpoint.markCleanupStarted(.init(taskID: task.id, items: [item]))
            XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task), "清单不能替换已完成内容的result")
        }
    }

    func testCleanupIntentSurvivesReloadAndPreventsResume() throws {
        try fixture { task, checkpoint in
            let plan = TransferCleanupPlan(taskID: task.id, items: [])
            try checkpoint.markCleanupStarted(plan)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint.fileURL)) as? [String: Any])
            XCTAssertEqual(json["version"] as? Int, 2, "旧版本必须拒绝清理中的检查点，不能忽略放弃状态后再续传")
            let restored = try TransferCheckpoint(fileURL: checkpoint.fileURL)
            XCTAssertEqual(restored.cleanupPlan, plan)
            XCTAssertThrowsError(try restored.requireResumable())
            let old = try JSONEncoder().encode(task)
            XCTAssertNil(try JSONDecoder().decode(RecoverableTransfer.self, from: old).cleanupStartedAt)
            var abandoned = task; abandoned.cleanupStartedAt = Date(timeIntervalSince1970: 100)
            XCTAssertEqual(try JSONDecoder().decode(RecoverableTransfer.self, from: JSONEncoder().encode(abandoned)), abandoned)
        }
    }
    func testUnstartedTaskAndBoundRootAreAccepted() throws {
        try fixture { task, checkpoint in
            XCTAssertTrue(try checkpoint.cleanupRoots(for: task).isEmpty)
            let root = try bind(task, checkpoint)
            XCTAssertEqual(try checkpoint.cleanupRoots(for: task).map(\.id), [root.id])
        }
    }

    func testNestedStagingAndMergeGraphsUseTheirOriginalPaths() throws {
        for merge in [false, true] {
            try fixture { task, checkpoint in
                var root = try bind(task, checkpoint, directory: true)
                root.choice = merge ? "merge" : "new"
                root.phase = merge ? "merging" : "copying"
                root = replacingSnapshot(root, directorySnapshot(["子目录": directorySnapshot(["a.txt": fileSnapshot])]))
                try save(root, checkpoint)
                var child = record(checkpoint, source: root.source + "/子目录", requested: (merge ? root.target : root.temporary) + "/子目录", snapshot: root.sourceSnapshot.children!["子目录"]!)
                child.phase = "complete"; child.result = child.sourceSnapshot
                try save(child, checkpoint)
                let leaf = record(checkpoint, source: child.source + "/a.txt", requested: child.temporary + "/a.txt", snapshot: fileSnapshot)
                try save(leaf, checkpoint)
                XCTAssertEqual(try checkpoint.cleanupRoots(for: task).count, 1)
            }
        }
    }

    func testExtraRootOrRecordCannotAuthorizeOtherPaths() throws {
        try fixture { task, checkpoint in
            _ = try bind(task, checkpoint)
            try checkpoint.bindRoot(source: "/other/source", requested: "/remote/other", upload: true, resolvedSource: "/other/source", resolvedTarget: "/remote/other")
            XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task))
        }
        try fixture { task, checkpoint in
            _ = try bind(task, checkpoint)
            try save(record(checkpoint, source: "/other/source", requested: "/remote/other", snapshot: fileSnapshot), checkpoint)
            XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task))
        }
    }

    func testUnsafeChildrenUnrelatedKeepBothAndWrongRootBindingAreRejected() throws {
        for name in ["..", "../outside", "/outside", "bad\0name"] {
            try fixture { task, checkpoint in
                var root = try bind(task, checkpoint, directory: true)
                root = replacingSnapshot(root, directorySnapshot([name: fileSnapshot]))
                try save(root, checkpoint)
                XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task), name)
            }
        }
        try fixture { task, checkpoint in
            var root = try bind(task, checkpoint)
            root.choice = "keepBoth"; root.target = "/remote/someone-else.txt"
            try save(root, checkpoint)
            XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task))
            root.target = "/remote/a (2).txt"
            try save(root, checkpoint)
            XCTAssertEqual(try checkpoint.cleanupRoots(for: task).count, 1)
        }
        try fixture { task, checkpoint in
            try checkpoint.bindRoot(source: task.roots[0].localPath, requested: "/remote/a.txt", upload: true,
                                    resolvedSource: "/unrelated/a.txt", resolvedTarget: "/remote/a.txt")
            XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task))
        }
    }

    func testWrongChildSnapshotOrDestinationCannotBeHiddenInGraph() throws {
        for wrongPath in [false, true] {
            try fixture { task, checkpoint in
                var root = try bind(task, checkpoint, directory: true)
                root = replacingSnapshot(root, directorySnapshot(["a.txt": fileSnapshot])); root.phase = "copying"
                try save(root, checkpoint)
                var child = record(checkpoint, source: root.source + "/a.txt", requested: (wrongPath ? root.target : root.temporary) + "/a.txt", snapshot: fileSnapshot)
                if !wrongPath { var snapshot = fileSnapshot; snapshot.size = 999; child = replacingSnapshot(child, snapshot) }
                try save(child, checkpoint)
                XCTAssertThrowsError(try checkpoint.cleanupRoots(for: task))
            }
        }
    }

    private func replacingSnapshot(_ record: TransferCheckpoint.Record, _ snapshot: TransferCheckpoint.Snapshot) -> TransferCheckpoint.Record {
        .init(id: record.id, source: record.source, requested: record.requested, upload: record.upload, canKeepBoth: record.canKeepBoth, sourceSnapshot: snapshot, target: record.target, previous: record.previous, choice: record.choice, phase: record.phase)
    }
    private var fileSnapshot: TransferCheckpoint.Snapshot { .init(directory: false, size: 10, modified: 1, digest: "hash") }
    private func directorySnapshot(_ children: [String: TransferCheckpoint.Snapshot] = [:]) -> TransferCheckpoint.Snapshot {
        .init(directory: true, modified: 1, children: children)
    }
    private func record(_ checkpoint: TransferCheckpoint, source: String, requested: String, snapshot: TransferCheckpoint.Snapshot) -> TransferCheckpoint.Record {
        .init(id: checkpoint.identifier(for: TransferCheckpoint.key(upload: true, source: source, requested: requested)), source: source,
              requested: requested, upload: true, canKeepBoth: true, sourceSnapshot: snapshot, target: requested, choice: "new")
    }
    private func save(_ record: TransferCheckpoint.Record, _ checkpoint: TransferCheckpoint) throws {
        try checkpoint.save(record, key: TransferCheckpoint.key(upload: record.upload, source: record.source, requested: record.requested))
    }
    private func bind(_ task: RecoverableTransfer, _ checkpoint: TransferCheckpoint, directory: Bool = false) throws -> TransferCheckpoint.Record {
        let source = task.roots[0].localPath, target = task.roots[0].remotePath
        try checkpoint.bindRoot(source: source, requested: target, upload: true, resolvedSource: source, resolvedTarget: target)
        let result = record(checkpoint, source: source, requested: target, snapshot: directory ? directorySnapshot() : fileSnapshot)
        try save(result, checkpoint)
        return result
    }
    private func fixture(_ body: (RecoverableTransfer, TransferCheckpoint) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = RecoverableTransfer(account: .init(profile: .init(name: "test", host: "example.test")), name: "test", direction: .upload,
                                       roots: [.init(localPath: directory.appendingPathComponent("a.txt").path, remotePath: "/remote/a.txt")])
        let checkpoint = try TransferCheckpoint(fileURL: directory.appendingPathComponent("checkpoint.json"))
        try body(task, checkpoint)
    }
}
