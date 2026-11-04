import XCTest
@testable import Nc2ShellCore

final class TransferMetadataTests: XCTestCase {
    private func checkpoint(_ options: TransferAttributeOptions = .init(preservePermissions: true, preserveModificationTime: true)) throws -> (TransferCheckpoint, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("nc2-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (try TransferCheckpoint(fileURL: root.appendingPathComponent("checkpoint.json"), attributes: options), root)
    }

    func testEnabledOptionsUseVersionThreeAndCannotChangeOnRestart() throws {
        let (cp, root) = try checkpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try Data(contentsOf: cp.fileURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 3)
        XCTAssertTrue(try TransferCheckpoint(fileURL: cp.fileURL).attributes.isEnabled)
        XCTAssertThrowsError(try TransferCheckpoint(fileURL: cp.fileURL, attributes: .init()))
        XCTAssertThrowsError(try TransferCheckpoint(fileURL: cp.fileURL, attributes: .init(preserveModificationTime: true)))
        XCTAssertEqual(try Data(contentsOf: cp.fileURL), data)
        var downgraded = json; downgraded["version"] = 1
        try JSONSerialization.data(withJSONObject: downgraded).write(to: cp.fileURL)
        XCTAssertThrowsError(try TransferCheckpoint(fileURL: cp.fileURL))
    }

    func testRegistrationProtectsUnstartedTasksAndDoesNotChangeTheirOptions() throws {
        let (_, root) = try checkpoint(.init())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferRecoveryStore(directoryURL: root.appendingPathComponent("tasks"))
        let profile = ConnectionProfile(name: "test", host: "test")
        let options = TransferAttributeOptions(preserveModificationTime: true)
        let task = RecoverableTransfer(account: .init(profile: profile), name: "file", direction: .upload,
                                       roots: [.init(localPath: "/local/file", remotePath: "/remote/file")], attributes: options)
        try store.save(task)
        XCTAssertEqual(try TransferCheckpoint(fileURL: store.checkpointURL(for: task.id)).attributes, options)
        let changed = RecoverableTransfer(id: task.id, account: task.account, name: task.name, direction: task.direction, roots: task.roots)
        XCTAssertThrowsError(try store.save(changed))
        XCTAssertEqual(try store.load().first?.attributes, options)
    }

    func testInstalledTreeMappingUsesActualRootAndPreservesSpecialBitsOnlyInEvidence() throws {
        let (cp, root) = try checkpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        try cp.begin(); defer { cp.end() }
        let file = TransferCheckpoint.Snapshot(directory: false, size: 3, modified: 123, digest: "abc", mode: 0o4750)
        let source = TransferCheckpoint.Snapshot(directory: true, modified: 456, children: ["a": file], mode: 0o1755)
        var parent = record(cp, source: "/source/folder", requested: "/remote/folder", snapshot: source)
        parent.result = .init(directory: true, modified: 999, children: ["a": .init(directory: false, size: 3, modified: 998, digest: "abc", mode: 0o600)], mode: 0o700)
        let child = record(cp, source: "/source/folder/a", requested: parent.temporary + "/a", snapshot: file)
        try cp.bindRoot(source: parent.source, requested: parent.requested, upload: true, resolvedSource: parent.source, resolvedTarget: parent.requested)
        try cp.save(parent, key: key(parent)); try cp.save(child, key: key(child))
        let items = try cp.metadataItems(for: parent)
        XCTAssertEqual(items.map(\.path), ["/remote/folder/a", "/remote/folder"])
        XCTAssertEqual(items.map(\.permissions), [0o750, 0o755])
        XCTAssertEqual(items.map(\.modifiedTime), [123, 456])
        XCTAssertEqual(items.first?.original.mode, 0o600)
        XCTAssertNil(cp.metadataProgress(for: key(parent)))
        try cp.saveMetadataProgress([key(child): "applying"], for: key(parent))
        XCTAssertEqual(cp.metadataProgress(for: key(parent))?[key(child)], "applying")
        XCTAssertThrowsError(try cp.saveMetadataProgress(["arbitrary": "applying"], for: key(parent)))
        XCTAssertThrowsError(try cp.saveMetadataProgress([key(child): "unknown"], for: key(parent)))
    }

    func testMergeSkipsExistingDirectoryAndSkippedChildButMapsRenamedChild() throws {
        let (cp, root) = try checkpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        try cp.begin(); defer { cp.end() }
        let file = TransferCheckpoint.Snapshot(directory: false, size: 1, modified: 10, digest: "a", mode: 0o644)
        let snapshot = TransferCheckpoint.Snapshot(directory: true, modified: 20, children: ["a.txt": file, "skip": file], mode: 0o755)
        var parent = record(cp, source: "/source/folder", requested: "/remote/folder", snapshot: snapshot)
        parent.choice = "merge"
        parent.result = .init(directory: true, modified: 30, children: ["a.txt": file, "a (2).txt": file, "skip": file], mode: 0o700)
        var child = record(cp, source: "/source/folder/a.txt", requested: "/remote/folder/a.txt", snapshot: file)
        child.choice = "keepBoth"; child.target = "/remote/folder/a (2).txt"
        var skipped = record(cp, source: "/source/folder/skip", requested: "/remote/folder/skip", snapshot: file)
        skipped.choice = "skip"; skipped.phase = "skipped"
        try cp.bindRoot(source: parent.source, requested: parent.requested, upload: true, resolvedSource: parent.source, resolvedTarget: parent.requested)
        for entry in [parent, child, skipped] { try cp.save(entry, key: key(entry)) }
        XCTAssertEqual(try cp.metadataItems(for: parent).map(\.path), ["/remote/folder/a (2).txt"])
        child.target = "/remote/folder/outside"
        try cp.save(child, key: key(child))
        XCTAssertThrowsError(try cp.metadataItems(for: parent))
    }

    func testMissingChildOrUnknownSourceAttributesCannotAuthorizeMetadataWrite() throws {
        let (cp, root) = try checkpoint()
        defer { try? FileManager.default.removeItem(at: root) }
        try cp.begin(); defer { cp.end() }
        let child = TransferCheckpoint.Snapshot(directory: false, size: 1, modified: 10, digest: "a", mode: 0o644)
        let snapshot = TransferCheckpoint.Snapshot(directory: true, modified: 20, children: ["missing": child], mode: 0o755)
        let parent = record(cp, source: "/source/folder", requested: "/remote/folder", snapshot: snapshot)
        try cp.bindRoot(source: parent.source, requested: parent.requested, upload: true, resolvedSource: parent.source, resolvedTarget: parent.requested)
        try cp.save(parent, key: key(parent))
        XCTAssertThrowsError(try cp.metadataItems(for: parent))
        for modified in [nil, -1, Double(UInt32.max) + 1] as [Double?] {
            let bad = record(cp, source: "/source/file", requested: "/remote/file", snapshot: .init(directory: false, size: 1, modified: modified, mode: 0o644))
            try cp.bindRoot(source: bad.source, requested: bad.requested, upload: true, resolvedSource: bad.source, resolvedTarget: bad.requested)
            try cp.save(bad, key: key(bad))
            XCTAssertThrowsError(try cp.metadataItems(for: bad))
        }
    }

    private func key(_ record: TransferCheckpoint.Record) -> String {
        TransferCheckpoint.key(upload: record.upload, source: record.source, requested: record.requested)
    }

    private func record(_ cp: TransferCheckpoint, source: String, requested: String, snapshot: TransferCheckpoint.Snapshot) -> TransferCheckpoint.Record {
        let key = TransferCheckpoint.key(upload: true, source: source, requested: requested)
        return .init(id: cp.identifier(for: key), source: source, requested: requested, upload: true, canKeepBoth: true,
                     sourceSnapshot: snapshot, target: requested, choice: "new", phase: "complete", result: snapshot)
    }
}
