import XCTest
import Nc2ShellCore
@testable import Nc2Shell

@MainActor
final class WorkspaceSettingsTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-settings-sheet-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testDraftEditsAndPageResetDoNotSaveOrChangeOtherPages() throws {
        let root = try directory()
        let terminalStore = TerminalSettingsStore(fileURL: root.appendingPathComponent("terminal.json"))
        let transferStore = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer.json"))
        var original = TerminalPreferences()
        original.fontSize = 20
        original.shortcuts[.find] = AppShortcut(key: "k")
        try terminalStore.save(original)
        let transfer = TransferPreferences(maxConcurrentTransfers: 4, uploadLimitKiB: 128)
        try transferStore.save(transfer)
        var draft = WorkspaceSettingsDraft(terminal: original, transfer: transfer)
        draft.terminal.fontSize = 24
        draft.terminal.shortcuts[.find] = AppShortcut(key: "j")
        draft.transfer.uploadLimit = "512"
        draft.reset(.terminal)
        XCTAssertEqual(draft.terminal.fontSize, 16)
        XCTAssertEqual(draft.terminal.shortcuts[.find], AppShortcut(key: "j"))
        XCTAssertEqual(draft.transfer.uploadLimit, "512")
        draft.reset(.shortcuts)
        XCTAssertEqual(draft.terminal.shortcuts, TerminalPreferences().shortcuts)
        XCTAssertEqual(draft.transfer.uploadLimit, "512")
        draft.reset(.transfers)
        XCTAssertEqual(try draft.transfer.validated(), TransferPreferences())
        XCTAssertEqual(try terminalStore.load(), original)
        XCTAssertEqual(try transferStore.load(), transfer)
        let reopened = WorkspaceSettingsDraft(terminal: try terminalStore.load(), transfer: try transferStore.load())
        XCTAssertEqual(reopened.terminal, original)
        XCTAssertEqual(try reopened.transfer.validated(), transfer)
    }

    func testInvalidTransferTextAndRangeAreRejected() throws {
        var draft = WorkspaceSettingsDraft(terminal: TerminalPreferences(), transfer: TransferPreferences())
        for value in ["", "abc", "1.5", "-1", "1048577"] {
            draft.transfer.uploadLimit = value
            XCTAssertThrowsError(try draft.transfer.validated(), value)
        }
        draft.transfer.uploadLimit = " 128 "
        draft.transfer.downloadLimit = "1048576"
        XCTAssertEqual(try draft.transfer.validated().uploadLimitKiB, 128)
        XCTAssertEqual(try draft.transfer.validated().downloadLimitKiB, 1_048_576)
    }

    func testUnifiedSaveValidatesAllPagesBeforeWritingAndAppliesBoth() throws {
        let root = try directory()
        let terminalStore = TerminalSettingsStore(fileURL: root.appendingPathComponent("terminal.json"))
        let transferStore = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer.json"))
        let original = TerminalPreferences(), originalTransfer = TransferPreferences()
        try terminalStore.save(original)
        try transferStore.save(originalTransfer)
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: terminalStore,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let controller = TransferSettingsController(store: transferStore)
        let limiter = controller.limiter
        let oldTerminalBytes = try Data(contentsOf: terminalStore.fileURL), oldTransferBytes = try Data(contentsOf: transferStore.fileURL)
        var changed = original
        changed.theme = .light
        changed.fontSize = 22
        changed.scrollbackLines = 50_000
        changed.optionAsMetaKey = false
        changed.shortcuts[.find] = changed.shortcuts[.splitColumns]
        XCTAssertThrowsError(try model.saveSettings(terminal: changed, transfer: .init(uploadLimitKiB: 512), controller: controller))
        changed.shortcuts[.find] = AppShortcut(key: "k")
        XCTAssertThrowsError(try model.saveSettings(terminal: changed, transfer: .init(downloadLimitKiB: -1), controller: controller))
        XCTAssertEqual(try Data(contentsOf: terminalStore.fileURL), oldTerminalBytes)
        XCTAssertEqual(try Data(contentsOf: transferStore.fileURL), oldTransferBytes)
        XCTAssertEqual(model.preferences, original)
        XCTAssertEqual(controller.preferences, originalTransfer)
        let transfer = TransferPreferences(maxConcurrentTransfers: 3, uploadLimitKiB: 512, attributes: .init(preservePermissions: true))
        try model.saveSettings(terminal: changed, transfer: transfer, controller: controller)
        XCTAssertEqual(try terminalStore.load(), changed)
        XCTAssertEqual(try transferStore.load(), transfer)
        XCTAssertEqual(model.preferences, changed)
        XCTAssertEqual(controller.preferences, transfer)
        XCTAssertTrue(controller.limiter === limiter)
    }

    func testCorruptTransferFilePreventsTerminalSave() throws {
        let root = try directory()
        let terminalStore = TerminalSettingsStore(fileURL: root.appendingPathComponent("terminal.json"))
        let transferStore = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer.json"))
        try terminalStore.save(TerminalPreferences())
        let original = try Data(contentsOf: terminalStore.fileURL)
        let broken = Data("broken".utf8)
        try broken.write(to: transferStore.fileURL)
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: terminalStore,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let controller = TransferSettingsController(store: transferStore)
        var changed = model.preferences
        changed.fontSize = 22
        XCTAssertThrowsError(try model.saveSettings(terminal: changed, transfer: TransferPreferences(), controller: controller))
        XCTAssertEqual(try Data(contentsOf: terminalStore.fileURL), original)
        XCTAssertEqual(try Data(contentsOf: transferStore.fileURL), broken)
    }

    func testSecondWriteFailureRestoresOriginalTerminalBytesOrAbsence() throws {
        for existing in [true, false] {
            let root = try directory()
            let terminalStore = TerminalSettingsStore(fileURL: root.appendingPathComponent("terminal.json"))
            if existing { try JSONEncoder().encode(TerminalPreferences()).write(to: terminalStore.fileURL) }
            let original = try? Data(contentsOf: terminalStore.fileURL)
            // 父目录尚不存在时读入为默认值；创建目录后，超长文件名使第二次写入失败。
            let blockedParent = root.appendingPathComponent("not-created-yet")
            let transferStore = TransferPreferencesStore(fileURL: blockedParent.appendingPathComponent(String(repeating: "x", count: 300) + ".json"))
            XCTAssertNoThrow(try transferStore.load())
            let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: terminalStore,
                                 sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
            let controller = TransferSettingsController(store: transferStore)
            var changed = model.preferences
            changed.fontSize = 22
            XCTAssertThrowsError(try model.saveSettings(terminal: changed, transfer: TransferPreferences(), controller: controller))
            XCTAssertTrue(FileManager.default.fileExists(atPath: blockedParent.path), "应实际进入第二份设置写入，不能只覆盖预检失败")
            XCTAssertEqual(try? Data(contentsOf: terminalStore.fileURL), original)
            XCTAssertEqual(model.preferences, TerminalPreferences())
            XCTAssertEqual(controller.preferences, TransferPreferences())
        }
    }

    func testSettingsAndConnectionEditorCannotReplaceEachOther() throws {
        let root = try directory()
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: .init(fileURL: root.appendingPathComponent("terminal.json")),
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        model.newConnection()
        model.showSettings()
        XCTAssertFalse(model.settingsPresented)
        model.editor = nil
        model.showSettings()
        XCTAssertTrue(model.settingsPresented)
        model.newConnection()
        XCTAssertNil(model.editor)
        XCTAssertFalse(model.canPerform(.newConnection))
        model.settingsPresented = false
        XCTAssertTrue(model.canPerform(.newConnection))
    }
}
