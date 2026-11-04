import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class TransferConflictPresentationTests: XCTestCase {
    private let conflict = TransferConflict(sourcePath: "/source/a", destinationPath: "/target/a",
                                            sourceIsDirectory: false, destinationIsDirectory: false, canKeepBoth: true)

    @MainActor
    private final class Display {
        var events: [String] = []
        var visible: Set<String> = []
        var maximumVisible = 0
        var replies: [String: TransferConflictPrompt.Reply] = [:]
        var synchronous: Set<String> = []

        func present(_ server: String, _ conflict: TransferConflict, _ reply: @escaping TransferConflictPrompt.Reply) -> () -> Void {
            events.append("show \(server)"); visible.insert(server)
            maximumVisible = max(maximumVisible, visible.count)
            replies[server] = reply
            if synchronous.contains(server) {
                reply(.skip, true)
                reply(.replace, true)
            }
            return {
                self.events.append("close \(server)"); self.visible.remove(server)
                // AppKit 结束 sheet 时仍可能交付一次取消响应。
                reply(.cancel, false)
            }
        }
    }

    @MainActor
    func testIndependentPromptsShowOneAtATimeAndRememberTheirOwnChoice() async throws {
        let display = Display()
        let first = TransferConflictPrompt(server: "first", present: display.present)
        let second = TransferConflictPrompt(server: "second", present: display.present)
        defer { first.cancel(); second.cancel() }
        let firstTask = Task { try await first.resolve(conflict) }
        try await eventually { display.replies["first"] != nil }
        var secondEntered = false
        let secondTask = Task { secondEntered = true; return try await second.resolve(conflict) }
        try await eventually { secondEntered }
        XCTAssertEqual(display.events, ["show first"])
        display.replies["first"]?(.skip, true)
        let firstResult = try await firstTask.value
        XCTAssertEqual(firstResult, .skip)
        try await eventually { display.replies["second"] != nil }
        display.replies["second"]?(.replace, true)
        let secondResult = try await secondTask.value
        XCTAssertEqual(secondResult, .replace)
        let firstRemembered = try await first.resolve(conflict)
        let secondRemembered = try await second.resolve(conflict)
        XCTAssertEqual(firstRemembered, .skip)
        XCTAssertEqual(secondRemembered, .replace)
        XCTAssertEqual(display.maximumVisible, 1)
        XCTAssertEqual(display.events, ["show first", "close first", "show second", "close second"])
    }

    @MainActor
    func testCancellingQueuedPromptFinishesBeforeActivePromptAndNeverShowsIt() async throws {
        let display = Display()
        let first = TransferConflictPrompt(server: "first", present: display.present)
        let cancelled = TransferConflictPrompt(server: "cancelled", present: display.present)
        let next = TransferConflictPrompt(server: "next", present: display.present)
        defer { first.cancel(); cancelled.cancel(); next.cancel() }
        let firstTask = Task { try await first.resolve(conflict) }
        try await eventually { display.replies["first"] != nil }
        var cancelledEntered = false
        let cancelledTask = Task { cancelledEntered = true; return try await cancelled.resolve(conflict) }
        try await eventually { cancelledEntered }
        var nextEntered = false
        let nextTask = Task { nextEntered = true; return try await next.resolve(conflict) }
        try await eventually { nextEntered }
        cancelled.cancel(); cancelled.cancel()
        let cancelledResult = try await cancelledTask.value
        XCTAssertEqual(cancelledResult, .cancel)
        XCTAssertEqual(display.events, ["show first"])
        first.cancel()
        let firstResult = try await firstTask.value
        XCTAssertEqual(firstResult, .cancel)
        try await eventually { display.replies["next"] != nil }
        display.replies["next"]?(.skip, false)
        let nextResult = try await nextTask.value
        XCTAssertEqual(nextResult, .skip)
        XCTAssertEqual(display.events, ["show first", "close first", "show next", "close next"])
        XCTAssertNil(display.replies["cancelled"])
    }

    @MainActor
    func testCancellingQueuedResolverTaskDoesNotShowItsPromptLater() async throws {
        let display = Display()
        let first = TransferConflictPrompt(server: "first", present: display.present)
        let waiting = TransferConflictPrompt(server: "waiting", present: display.present)
        defer { first.cancel(); waiting.cancel() }
        let firstTask = Task { try await first.resolve(conflict) }
        try await eventually { display.replies["first"] != nil }
        var waitingEntered = false
        let waitingTask = Task { waitingEntered = true; return try await waiting.resolve(conflict) }
        try await eventually { waitingEntered }
        waitingTask.cancel()
        let result = try await waitingTask.value
        XCTAssertEqual(result, .cancel)
        XCTAssertEqual(display.events, ["show first"])
        display.replies["first"]?(.replace, false)
        _ = try await firstTask.value
        XCTAssertEqual(display.events, ["show first", "close first"])
    }

    @MainActor
    func testSynchronousAndDuplicateRepliesCloseBeforeNextPromptStarts() async throws {
        let display = Display(); display.synchronous.insert("synchronous")
        let first = TransferConflictPrompt(server: "first", present: display.present)
        let synchronous = TransferConflictPrompt(server: "synchronous", present: display.present)
        let next = TransferConflictPrompt(server: "next", present: display.present)
        defer { first.cancel(); synchronous.cancel(); next.cancel() }
        let firstTask = Task { try await first.resolve(conflict) }
        try await eventually { display.replies["first"] != nil }
        var synchronousEntered = false
        let synchronousTask = Task { synchronousEntered = true; return try await synchronous.resolve(conflict) }
        try await eventually { synchronousEntered }
        var nextEntered = false
        let nextTask = Task { nextEntered = true; return try await next.resolve(conflict) }
        try await eventually { nextEntered }
        display.replies["first"]?(.replace, false)
        _ = try await firstTask.value
        let synchronousResult = try await synchronousTask.value
        XCTAssertEqual(synchronousResult, .skip)
        try await eventually { display.replies["next"] != nil }
        display.replies["synchronous"]?(.replace, true)
        display.replies["next"]?(.replace, false)
        let nextResult = try await nextTask.value
        XCTAssertEqual(nextResult, .replace)
        XCTAssertFalse(synchronous.wasCancelledByUser)
        XCTAssertEqual(display.maximumVisible, 1)
        XCTAssertEqual(display.events, ["show first", "close first", "show synchronous", "close synchronous", "show next", "close next"])
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "ConflictPresentationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待提示展示超时"])
    }
}
