import XCTest
import Combine
@testable import Nc2Shell

final class RemoteNavigationTests: XCTestCase {
    @MainActor
    func testHistoryMovesOnlyAfterSuccessfulCommit() throws {
        let navigation = RemoteNavigationState()
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)
        navigation.commit("/home/nc")
        navigation.commit("/srv")
        let back = try XCTUnwrap(navigation.backTarget)
        XCTAssertEqual(back.path, "/home/nc")
        XCTAssertEqual(back.index, 0)
        // 失败或取消只是不提交，读取目标不会提前改变当前目录。
        XCTAssertEqual(navigation.currentPath, "/srv")
        XCTAssertNil(navigation.forwardTarget)
        navigation.commit("/home/nc", target: back)
        XCTAssertEqual(navigation.currentPath, "/home/nc")
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertTrue(navigation.canGoForward)
        let forward = try XCTUnwrap(navigation.forwardTarget)
        XCTAssertEqual(forward.path, "/srv")
        navigation.commit("/srv", target: forward)
        XCTAssertEqual(navigation.paths, ["/home/nc", "/srv"])
        XCTAssertFalse(navigation.canGoForward)
    }

    @MainActor
    func testRefreshPreservesForwardHistoryAndNewNavigationCutsTheBranch() throws {
        let navigation = RemoteNavigationState()
        navigation.commit("/a")
        navigation.commit("/b")
        navigation.commit("/c")
        navigation.commit("/b", target: try XCTUnwrap(navigation.backTarget))
        navigation.commit("/b")
        XCTAssertEqual(navigation.paths, ["/a", "/b", "/c"])
        XCTAssertEqual(navigation.forwardTarget?.path, "/c")
        navigation.commit("/d")
        XCTAssertEqual(navigation.paths, ["/a", "/b", "/d"])
        XCTAssertEqual(navigation.backTarget?.path, "/b")
        XCTAssertNil(navigation.forwardTarget)
    }

    @MainActor
    func testHistoryCommitUsesResolvedPathWithoutAddingAnEntry() throws {
        let navigation = RemoteNavigationState()
        navigation.commit("/old-directory")
        navigation.commit("/elsewhere")
        navigation.commit("/resolved-directory", target: try XCTUnwrap(navigation.backTarget))
        XCTAssertEqual(navigation.paths, ["/resolved-directory", "/elsewhere"])
        XCTAssertEqual(navigation.currentPath, "/resolved-directory")
    }

    @MainActor
    func testResetAndNewBranchRejectOldHistoryTargets() throws {
        let navigation = RemoteNavigationState()
        navigation.commit("/a")
        navigation.commit("/b")
        let oldBack = try XCTUnwrap(navigation.backTarget)
        navigation.commit("/c")
        navigation.commit("/a", target: oldBack)
        XCTAssertEqual(navigation.currentPath, "/c")
        let beforeReset = try XCTUnwrap(navigation.backTarget)
        navigation.reset()
        XCTAssertNil(navigation.currentPath)
        XCTAssertEqual(navigation.paths, [])
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)
        navigation.commit("/a")
        navigation.commit("/b")
        navigation.commit("/c")
        navigation.commit("/b", target: beforeReset)
        XCTAssertEqual(navigation.index, 2)
        XCTAssertEqual(navigation.paths, ["/a", "/b", "/c"])
    }

    @MainActor
    func testObserversCanReadCurrentPathDuringReset() {
        let navigation = RemoteNavigationState()
        navigation.commit("/a")
        navigation.commit("/b")
        var observed: [String?] = []
        var backAvailable: [Bool] = []
        let observation = navigation.objectWillChange.sink {
            observed.append(navigation.currentPath)
            backAvailable.append(navigation.canGoBack)
            XCTAssertFalse(navigation.canGoForward)
        }
        defer { observation.cancel() }
        navigation.reset()
        XCTAssertNil(navigation.currentPath)
        XCTAssertEqual(observed.first ?? nil, "/b")
        XCTAssertTrue(observed.dropFirst().allSatisfy { $0 == nil })
        XCTAssertEqual(backAvailable.first, true)
        XCTAssertTrue(backAvailable.dropFirst().allSatisfy { !$0 })
    }

    @MainActor
    func testBreadcrumbsPreserveRawUnicodeWhitespaceAndShellCharacters() {
        let crumbs = RemoteNavigationState.breadcrumbs(for: "/home/a ' b/中文\n 尾 ")
        XCTAssertEqual(crumbs.map(\.name), ["/", "home", "a ' b", "中文\n 尾 "])
        XCTAssertEqual(crumbs.map(\.path), ["/", "/home", "/home/a ' b", "/home/a ' b/中文\n 尾 "])
        XCTAssertEqual(RemoteNavigationState.breadcrumbs(for: "/").map(\.path), ["/"])
        XCTAssertEqual(RemoteNavigationState.breadcrumbs(for: "/a//b").map(\.path), ["/", "/a", "/a//b"])
        XCTAssertTrue(RemoteNavigationState.breadcrumbs(for: "").isEmpty)
        XCTAssertTrue(RemoteNavigationState.breadcrumbs(for: "relative/path").isEmpty)
    }
}
