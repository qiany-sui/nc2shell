import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class TransferConflictPromptTests: XCTestCase {
    private func conflict(directory: Bool = false, canKeepBoth: Bool = true) -> TransferConflict {
        TransferConflict(sourcePath: "/source/a", destinationPath: "/target/a",
                         sourceIsDirectory: directory, destinationIsDirectory: directory, canKeepBoth: canKeepBoth)
    }

    @MainActor
    func testApplyToBatchIsLimitedToMatchingTypesAndKeepsFinderTarget() async throws {
        var reply: TransferConflictPrompt.Reply?
        var presentations = 0
        let prompt = TransferConflictPrompt(server: "test") { _, _, callback in
            presentations += 1; reply = callback; return {}
        }
        let first = Task { try await prompt.resolve(conflict()) }
        await Task.yield()
        let respond = try XCTUnwrap(reply); respond(.keepBoth, true)
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, .keepBoth)
        let reused = try await prompt.resolve(conflict())
        XCTAssertEqual(reused, .keepBoth)
        XCTAssertEqual(presentations, 1)

        reply = nil
        let folder = Task { try await prompt.resolve(conflict(directory: true)) }
        await Task.yield()
        try XCTUnwrap(reply)(.merge, true)
        let folderResult = try await folder.value
        XCTAssertEqual(folderResult, .merge)
        XCTAssertEqual(presentations, 2, "目录冲突不能沿用普通文件的策略")

        reply = nil
        let finder = Task { try await prompt.resolve(conflict(canKeepBoth: false)) }
        await Task.yield()
        try XCTUnwrap(reply)(.replace, false)
        let finderResult = try await finder.value
        XCTAssertEqual(finderResult, .replace)
        XCTAssertEqual(presentations, 3, "Finder 给定目标不能沿用保留两份自动改名")
    }

    @MainActor
    func testCancellationClosesPendingPromptAndIgnoresLateResponse() async throws {
        var reply: TransferConflictPrompt.Reply?
        var closed = 0
        let prompt = TransferConflictPrompt(server: "test") { _, _, callback in
            reply = callback; return { closed += 1 }
        }
        let pending = Task { try await prompt.resolve(conflict()) }
        await Task.yield()
        let late = try XCTUnwrap(reply)
        prompt.cancel(); prompt.cancel()
        late(.replace, true)
        let result = try await pending.value
        XCTAssertEqual(result, .cancel)
        XCTAssertEqual(closed, 1)
        let afterCancel = try await prompt.resolve(conflict())
        XCTAssertEqual(afterCancel, .cancel, "取消本批后不能在后续项目重新弹框")
    }

    @MainActor
    func testResolverTaskCancellationFinishesWithoutUserResponse() async throws {
        var shown = false
        var closed = false
        let prompt = TransferConflictPrompt(server: "test") { _, _, _ in
            shown = true; return { closed = true }
        }
        let pending = Task { try await prompt.resolve(conflict()) }
        await Task.yield()
        XCTAssertTrue(shown)
        pending.cancel()
        let result = try await pending.value
        XCTAssertEqual(result, .cancel)
        XCTAssertTrue(closed)
    }
}
