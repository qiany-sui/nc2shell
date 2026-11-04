import XCTest
import Combine
import Nc2ShellCore
@testable import Nc2Shell

final class TransferPathReservationsTests: XCTestCase {
    @MainActor
    private func scopes(_ local: String, _ remote: String, upload: Bool) throws -> [TransferPathReservations.Scope] {
        try TransferPathReservations.Scope.capture(roots: [.init(localPath: local, remotePath: remote)], upload: upload)
    }

    @MainActor
    func testSharedSourcesRemainParallelButReadWriteAncestorsWait() throws {
        let reservations = TransferPathReservations()
        let first = UUID(), second = UUID()
        XCTAssertTrue(reservations.acquire(id: first, scopes: try scopes("/local/source", "/remote/a", upload: true)))
        XCTAssertTrue(reservations.acquire(id: second, scopes: try scopes("/local/source", "/remote/b", upload: true)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/download", "/remote/a/child", upload: false)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/source/child", "/remote/read", upload: false)))
        reservations.release(id: first); reservations.release(id: second)
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/a", "/remote/source", upload: false)))
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/b", "/remote/source", upload: false)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/input", "/remote/source/child", upload: true)))
    }

    @MainActor
    func testUnrelatedSiblingsAndLocalRemoteNamespacesRemainParallel() throws {
        let reservations = TransferPathReservations()
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/source", "/folder/a", upload: true)))
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/folder/a", "/folder/ab", upload: false)))
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/source", "/folder/b", upload: true)))
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/source", "/folder/a (1)", upload: true)))
    }

    @MainActor
    func testKeepBothFamiliesIncludeAncestorComponentsAndDottedDirectories() throws {
        let pairs = [
            ("/files/a.txt", "/files/a (2).txt"),
            ("/files/a.tar.gz", "/files/a.tar (2).gz"),
            ("/files/folder", "/files/folder (2)/child"),
            ("/files/folder.ext", "/files/folder.ext (2)/child"),
            ("/files/folder.tar.gz", "/files/folder.tar.gz (12)/child"),
            ("/files/a.txt", "/files/a (2) (3).txt"),
            ("/files/Résumé", "/files/re\u{301}sume\u{301}/child")
        ]
        for (written, read) in pairs {
            let reservations = TransferPathReservations()
            XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/input", written, upload: true)))
            XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/output", read, upload: false)), "不应同时访问：\(written) 与 \(read)")
        }
    }

    @MainActor
    func testNewlineNamesAndMultipleRootsAreNotParsedAsDisplayText() throws {
        let reservations = TransferPathReservations()
        let roots = [RecoverableTransfer.Root(localPath: "/local/first", remotePath: "/files/a\nb"),
                     RecoverableTransfer.Root(localPath: "/local/second", remotePath: "/files/second")]
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try TransferPathReservations.Scope.capture(roots: roots, upload: true)))
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/output-a", "/files/a", upload: false)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/output-full", "/files/a\nb", upload: false)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/output-second", "/files/second", upload: false)))
    }

    @MainActor
    func testFinalNewlineDoesNotTurnAnUnrelatedNameIntoACopySuffix() throws {
        let reservations = TransferPathReservations()
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/input", "/files/a\n", upload: true)))
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/output", "/files/a (2)\n", upload: false)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/copy-output", "/files/a\n (2)", upload: false)))
    }

    @MainActor
    func testExplicitTemporaryContentWaitsForSiblingWrites() throws {
        for prefix in ["upload", "download", "backup", "copy"] {
            let reservations = TransferPathReservations()
            XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/input", "/remote/final", upload: true)))
            XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/output", "/remote/.nc2shell-\(prefix)-\(UUID())/content", upload: false)))
        }
        let reservations = TransferPathReservations()
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/final", "/remote/source", upload: false)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/.nc2shell-download-\(UUID())/content", "/remote/target", upload: true)))
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: try scopes("/local/unrelated", "/remote/unrelated-target", upload: true)))
    }

    @MainActor
    func testLocalAliasesOverlapAndRetargetingInvalidatesCapturedScope() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Nc2Shell-reservations-\(UUID())")
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let alias = root.appendingPathComponent("alias")
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        try manager.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createSymbolicLink(at: alias, withDestinationURL: first)
        let captured = try scopes(alias.appendingPathComponent("new\nfile").path, "/remote/source", upload: false)
        for scope in captured { XCTAssertNoThrow(try scope.revalidate()) }
        let reservations = TransferPathReservations()
        XCTAssertTrue(reservations.acquire(id: UUID(), scopes: captured))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes(first.appendingPathComponent("new\nfile").path, "/remote/other", upload: false)))
        try manager.removeItem(at: alias)
        try manager.createSymbolicLink(at: alias, withDestinationURL: second)
        XCTAssertThrowsError(try captured.forEach { try $0.revalidate() })
    }

    @MainActor
    func testExclusiveReservationsAndDuplicateIDsCannotWeakenExistingProtection() throws {
        let reservations = TransferPathReservations()
        let first = UUID(), exclusive = UUID()
        XCTAssertTrue(reservations.isIdle)
        XCTAssertTrue(reservations.acquire(id: first, scopes: try scopes("/local/a", "/remote/a", upload: true)))
        XCTAssertFalse(reservations.acquire(id: first, scopes: try scopes("/local/b", "/remote/b", upload: true)))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/c", "/remote/a", upload: true)))
        XCTAssertFalse(reservations.acquireExclusive(id: exclusive))
        reservations.release(id: first)
        XCTAssertTrue(reservations.acquireExclusive(id: exclusive))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/other", "/remote/other", upload: true)))
        XCTAssertFalse(reservations.acquireExclusive(id: exclusive))
        reservations.release(id: exclusive)
        XCTAssertTrue(reservations.isIdle)
        XCTAssertTrue(reservations.acquire(id: exclusive, scopes: []))
        XCTAssertFalse(reservations.acquire(id: UUID(), scopes: try scopes("/local/other", "/remote/other", upload: true)))
        reservations.release(id: exclusive)
        XCTAssertTrue(reservations.isIdle)
    }

    @MainActor
    func testNotificationsAreAsynchronousAndCoalescedForAcquireAndRelease() async throws {
        let reservations = TransferPathReservations()
        let first = UUID(), second = UUID()
        var idle: [Bool] = []
        let observation = reservations.changes.sink { idle.append(reservations.isIdle) }
        defer { observation.cancel() }
        XCTAssertTrue(reservations.acquire(id: first, scopes: try scopes("/local/source", "/remote/a", upload: true)))
        XCTAssertTrue(reservations.acquire(id: second, scopes: try scopes("/local/source", "/remote/b", upload: true)))
        reservations.release(id: first)
        XCTAssertEqual(idle, [], "通知不能同步重入调度器")
        try await eventually { idle.count == 1 }
        XCTAssertEqual(idle, [false])
        XCTAssertFalse(reservations.acquire(id: second, scopes: []))
        reservations.release(id: UUID())
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(idle, [false], "失败预约和重复释放不应制造调度循环")
        reservations.release(id: second)
        XCTAssertEqual(idle, [false])
        try await eventually { idle.count == 2 }
        XCTAssertEqual(idle, [false, true])
    }

    @MainActor
    func testReleaseNotificationCanStartAnotherWaitingOwnerWithoutReentry() async throws {
        let reservations = TransferPathReservations()
        let first = UUID(), waiting = UUID()
        let captured = try scopes("/local/source", "/remote/shared", upload: true)
        XCTAssertTrue(reservations.acquire(id: first, scopes: captured))
        var started = false, notifications = 0, callbackDepth = 0, maximumDepth = 0
        let observation = reservations.changes.sink {
            callbackDepth += 1; maximumDepth = max(maximumDepth, callbackDepth)
            notifications += 1
            if !started { started = reservations.acquire(id: waiting, scopes: captured) }
            callbackDepth -= 1
        }
        defer { observation.cancel(); reservations.release(id: waiting) }
        try await eventually { notifications == 1 }
        XCTAssertFalse(started)
        reservations.release(id: first)
        try await eventually { started && notifications == 3 }
        XCTAssertEqual(maximumDepth, 1)
        XCTAssertFalse(reservations.isIdle)
    }

    @MainActor
    func testUnsafePathsAreRejectedBeforeReservation() throws {
        for path in ["relative", "/a/../b", "/a/./b", "/a\0b"] {
            XCTAssertThrowsError(try scopes(path, "/remote/a", upload: true))
            XCTAssertThrowsError(try scopes("/local/a", path, upload: true))
        }
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "PathReservationsTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待预约变更通知超时"])
    }
}
