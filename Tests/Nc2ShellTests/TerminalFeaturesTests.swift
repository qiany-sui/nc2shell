import XCTest
import AppKit
import SwiftTerm
import Nc2ShellCore
@testable import Nc2Shell

private final class PaletteReplyCapture: TerminalViewDelegate {
    private var reply = ""
    func color(_ index: Int, in view: TerminalView) throws -> SwiftTerm.Color {
        reply = ""
        view.feed(text: "\u{1b}]4;\(index);?\u{7}")
        let range = try XCTUnwrap(reply.range(of: "rgb:[0-9a-fA-F/]+", options: .regularExpression))
        return try XCTUnwrap(SwiftTerm.Color.parse(String(reply[range])))
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { reply += String(decoding: data, as: UTF8.self) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private final class TerminalInputCapture: TerminalViewDelegate {
    var bytes: [UInt8] = []
    var displayUpdates = 0
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { displayUpdates += 1 }
}

final class TerminalFeaturesTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-terminal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testDefaultSplitAndColumnPanelsPreserveLayoutAndSessions() throws {
        let root = try temporaryDirectory()
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let first = model.connect(.init(name: "布局", host: "example.test"))
        let workspaceID = try XCTUnwrap(model.selectedWorkspace?.id)
        let second = try XCTUnwrap(model.split())
        let terminals = [first.terminal, second.terminal]
        XCTAssertEqual(model.selectedWorkspace?.axis, .rows)
        XCTAssertTrue(model.sidebarVisible && model.filesVisible)
        model.resizeSplit(workspaceID, fraction: 0.32)
        XCTAssertEqual(try XCTUnwrap(model.selectedWorkspace?.splitFraction), 0.32, accuracy: 0.001)
        _ = model.split(.columns)
        XCTAssertFalse(model.sidebarVisible || model.filesVisible)
        model.filesVisible = true
        model.focus(first.id)
        XCTAssertTrue(model.filesVisible, "焦点切换不能再次收起用户手动打开的面板")
        _ = model.split(.rows)
        XCTAssertTrue(model.sidebarVisible && model.filesVisible)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertTrue(first.terminal === terminals[0] && second.terminal === terminals[1])

        model.sidebarVisible = false
        _ = model.split(.columns)
        XCTAssertFalse(model.sidebarVisible || model.filesVisible)
        let third = model.connect(.init(name: "其他标签", host: "other.test"))
        XCTAssertFalse(model.sidebarVisible, "进入前收起的连接栏应保持收起")
        XCTAssertTrue(model.filesVisible)
        model.selectWorkspace(workspaceID)
        XCTAssertFalse(model.sidebarVisible || model.filesVisible)
        XCTAssertEqual(try XCTUnwrap(model.selectedWorkspace?.splitFraction), 0.32, accuracy: 0.001)
        model.close(second)
        XCTAssertFalse(model.sidebarVisible)
        XCTAssertTrue(model.filesVisible, "关闭分屏后应恢复原面板状态")
        XCTAssertTrue(model.sessions.contains { $0 === first } && model.sessions.contains { $0 === third })
    }

    @MainActor
    func testSplitKeepsSessionsAndFocusAcrossTabsAndClosingOnePane() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(store: ConnectionStore(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: TerminalSettingsStore(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let first = model.connect(.init(name: "A", host: "example.test"))
        let firstTerminal = first.terminal
        let workspaceID = try XCTUnwrap(model.selectedWorkspace?.id)
        let second = try XCTUnwrap(model.split(.columns))
        let secondTerminal = second.terminal
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.files === second.files)
        XCTAssertTrue(model.selectedSession === second)
        model.focus(first.id)
        XCTAssertTrue(model.selectedSession === first)
        _ = model.split(.rows)
        XCTAssertEqual(model.sessions.count, 2, "切换方向不能创建第三个会话")
        XCTAssertEqual(model.selectedWorkspace?.axis, .rows)
        let third = model.connect(.init(name: "B", host: "other.test"))
        model.selectWorkspace(workspaceID)
        XCTAssertTrue(model.selectedSession === first)
        XCTAssertTrue(first.terminal === firstTerminal)
        XCTAssertTrue(second.terminal === secondTerminal)
        model.close(first)
        XCTAssertTrue(model.selectedSession === second)
        XCTAssertNil(model.selectedWorkspace?.secondarySessionID)
        XCTAssertTrue(model.sessions.contains { $0 === third })
    }

    func testPreferencesRoundTripRejectsDuplicateReservedAndCtrlOnlyShortcuts() throws {
        let root = try temporaryDirectory()
        let store = TerminalSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        var preferences = TerminalPreferences()
        preferences.theme = .light
        preferences.fontSize = 19
        preferences.shortcuts[.find] = AppShortcut(key: "k", shift: true)
        try store.save(preferences)
        XCTAssertEqual(try store.load(), preferences)
        var duplicate = preferences
        duplicate.shortcuts[.splitColumns] = preferences.shortcuts[.find]
        XCTAssertThrowsError(try store.save(duplicate))
        for key in ["c", "v", "q", "w", ",", "a", "z", "x", "h", "m"] {
            var reserved = preferences
            reserved.shortcuts[.find] = AppShortcut(key: key)
            XCTAssertThrowsError(try reserved.validated(), key)
        }
        var controlOnly = preferences
        controlOnly.shortcuts[.find] = AppShortcut(key: "c", command: false, control: true)
        XCTAssertThrowsError(try controlOnly.validated())
        for size in [9.0, 29.0, .infinity] {
            var invalid = preferences
            invalid.fontSize = size
            XCTAssertThrowsError(try invalid.validated())
        }
        XCTAssertEqual(try store.load(), preferences, "无效设置不能覆盖旧设置")
    }

    func testCorruptedPreferencesAreNotOverwritten() throws {
        let file = try temporaryDirectory().appendingPathComponent("settings.json")
        let original = Data("{broken".utf8)
        try original.write(to: file)
        let store = TerminalSettingsStore(fileURL: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(TerminalPreferences()))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    private func behaviorSettingsData(scrollback: Any = 50_000, optionAsMeta: Any = false) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalPreferences())) as? [String: Any])
        json["scrollbackLines"] = scrollback
        json["optionAsMetaKey"] = optionAsMeta
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testLegacyTerminalSettingsKeepAppearanceAndGainBehaviorDefaultsOnSave() throws {
        let file = try temporaryDirectory().appendingPathComponent("settings.json")
        var old = TerminalPreferences()
        old.theme = .light
        old.fontSize = 19
        old.shortcuts[.find] = AppShortcut(key: "k", shift: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "scrollbackLines")
        json.removeValue(forKey: "optionAsMetaKey")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let store = TerminalSettingsStore(fileURL: file)
        let loaded = try store.load()
        XCTAssertEqual(loaded.theme, .light)
        XCTAssertEqual(loaded.fontSize, 19)
        XCTAssertEqual(loaded.shortcuts[.find], AppShortcut(key: "k", shift: true))
        try store.save(loaded)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["scrollbackLines"] as? Int, 10_000)
        XCTAssertEqual(saved["optionAsMetaKey"] as? Bool, true)
    }

    func testTerminalBehaviorSettingsRoundTripAndRejectInvalidValuesWithoutOverwriting() throws {
        let file = try temporaryDirectory().appendingPathComponent("settings.json")
        let store = TerminalSettingsStore(fileURL: file)
        for lines in [5_000, 10_000, 50_000] {
            for meta in [true, false] {
                let data = try behaviorSettingsData(scrollback: lines, optionAsMeta: meta)
                try data.write(to: file)
                try store.save(store.load())
                let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                XCTAssertEqual(saved["scrollbackLines"] as? Int, lines)
                XCTAssertEqual(saved["optionAsMetaKey"] as? Bool, meta)
            }
        }
        let invalid = try [0, -1, 50_001, 10_001, "10000", NSNull(), true].map { try behaviorSettingsData(scrollback: $0) }
            + ["false", 0, NSNull()].map { try behaviorSettingsData(optionAsMeta: $0) }
        for data in invalid {
            try data.write(to: file)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(TerminalPreferences()))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    @MainActor
    func testBehaviorSettingsResizeRealHistoryWithoutReplacingTerminalOrAlternateScreen() throws {
        let session = TerminalSession(profile: .init(name: "History", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        session.applyPreferences(TerminalPreferences())
        let view = session.terminal
        view.feed(text: "HISTORY_EARLY\r\n" + (0..<6_000).map { "line-\($0)\r\n" }.joined() + "HISTORY_LATEST")
        XCTAssertTrue(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("HISTORY_EARLY"))
        let cursorRow = view.getTerminal().getCursorLocation().y
        view.feed(text: "\u{1b}[?1049hALT_SCREEN")
        let alternate = view.getTerminal().getBufferAsData(kind: .alt)
        let smaller = try JSONDecoder().decode(TerminalPreferences.self, from: behaviorSettingsData(scrollback: 5_000))
        session.applyPreferences(smaller)
        XCTAssertTrue(session.terminal === view)
        XCTAssertEqual(view.getTerminal().getBufferAsData(kind: .alt), alternate)
        view.feed(text: "\u{1b}[?1049l")
        XCTAssertEqual(view.getTerminal().getCursorLocation().y, cursorRow, "裁剪回滚不能改变备用屏幕退出时恢复的光标行")
        let trimmed = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertFalse(trimmed.contains("HISTORY_EARLY"))
        XCTAssertTrue(trimmed.contains("HISTORY_LATEST"))
        let larger = try JSONDecoder().decode(TerminalPreferences.self, from: behaviorSettingsData())
        session.applyPreferences(larger)
        view.feed(text: "\r\n" + (0..<11_000).map { "later-\($0)\r\n" }.joined())
        XCTAssertTrue(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("HISTORY_LATEST"))
    }

    @MainActor
    func testHistoryReductionClearsStaleManualAndSearchSelectionsIncludingDeferredChanges() throws {
        for mode in ["manual", "search", "deferred"] {
            let session = TerminalSession(profile: .init(name: "Selection", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
            session.applyPreferences(TerminalPreferences())
            let view = session.terminal
            view.feed(text: "EARLY_MATCH\r\n" + (0..<6_000).map { "line-\($0)\r\n" }.joined())
            if mode == "manual" { view.selection.select(row: 0) }
            else {
                session.searchText = "EARLY_MATCH"
                XCTAssertTrue(session.searchSummary.contains("1"))
            }
            XCTAssertTrue(view.selection.active)
            if mode == "deferred" { view.feed(text: "\u{1b}[?1049hALT_MATCH") }
            session.applyPreferences(try JSONDecoder().decode(TerminalPreferences.self, from: behaviorSettingsData(scrollback: 5_000)))
            if mode == "deferred" {
                session.searchText = "ALT_MATCH"
                XCTAssertTrue(view.selection.active)
                view.feed(text: "\u{1b}[?1049l")
            }
            XCTAssertFalse(view.selection.active, mode)
            XCTAssertEqual(session.searchSummary, "", mode)
        }
    }

    @MainActor
    func testHistoryResizeSchedulesDisplayEvenWithoutNewRemoteOutput() async throws {
        let session = TerminalSession(profile: .init(name: "Display", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        session.applyPreferences(TerminalPreferences())
        let view = session.terminal, capture = TerminalInputCapture()
        view.notifyUpdateChanges = true
        view.terminalDelegate = capture
        view.feed(text: (0..<6_000).map { "line-\($0)\r\n" }.joined())
        try await Task.sleep(nanoseconds: 100_000_000)
        capture.displayUpdates = 0
        session.applyPreferences(try JSONDecoder().decode(TerminalPreferences.self, from: behaviorSettingsData(scrollback: 5_000)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(capture.displayUpdates, 0, "远端静止时也要调度终端显示更新")
    }

    @MainActor
    func testOptionBehaviorChangesNativeKeyRoutingAndAppliesToExistingAndNewSessions() throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        let store = TerminalSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: store,
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let first = model.connect(.init(name: "A", host: "example.test")), view = first.terminal
        let capture = TerminalInputCapture()
        view.terminalDelegate = capture
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "∫", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        view.keyDown(with: event)
        XCTAssertEqual(capture.bytes, [0x1b, 0x62])
        capture.bytes = []
        let settings = try JSONDecoder().decode(TerminalPreferences.self, from: behaviorSettingsData())
        try model.savePreferences(settings)
        XCTAssertTrue(first.terminal === view)
        view.keyDown(with: event)
        XCTAssertEqual(String(decoding: capture.bytes, as: UTF8.self), "∫")
        let second = model.connect(.init(name: "B", host: "example.test"))
        XCTAssertFalse(second.terminal.optionAsMetaKey)
        XCTAssertEqual(second.terminal.getTerminal().options.scrollback, 50_000)
        XCTAssertEqual(try store.load(), settings)
        try model.savePreferences(TerminalPreferences())
        XCTAssertTrue(view.optionAsMetaKey)
        XCTAssertTrue(second.terminal.optionAsMetaKey)
        XCTAssertEqual(second.terminal.getTerminal().options.scrollback, 10_000)
    }

    func testShortcutAliasesCannotCreateHiddenConflicts() throws {
        var settings = TerminalPreferences()
        settings.shortcuts[.splitColumns] = AppShortcut(key: "=", shift: true)
        settings.shortcuts[.splitRows] = AppShortcut(key: "+")
        XCTAssertThrowsError(try settings.validated(), "同一物理按键的 Shift 标点不能绕过冲突检查")
        for shortcut in [AppShortcut(key: "q", shift: true), AppShortcut(key: "q", control: true), AppShortcut(key: "v", shift: true, option: true)] {
            settings = TerminalPreferences()
            settings.shortcuts[.find] = shortcut
            XCTAssertThrowsError(try settings.validated(), "保留系统退出/锁屏/粘贴组合")
        }
    }

    @MainActor
    func testNativeFocusUpdatesActivePaneAndDoesNotStealSearchField() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        let model = AppModel(store: ConnectionStore(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: TerminalSettingsStore(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let first = model.connect(.init(name: "A", host: "example.test"))
        let second = try XCTUnwrap(model.split(.columns))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content
        let firstHost = TerminalFocusContainer(terminal: first.terminal)
        let secondHost = TerminalFocusContainer(terminal: second.terminal)
        firstHost.onFocus = { model.focus(first.id, requestResponder: false) }
        secondHost.onFocus = { model.focus(second.id, requestResponder: false) }
        content.addSubview(firstHost); content.addSubview(secondHost)
        XCTAssertTrue(window.makeFirstResponder(first.terminal))
        firstHost.observeFocus(); secondHost.observeFocus()
        XCTAssertTrue(model.selectedSession === first)
        XCTAssertTrue(window.makeFirstResponder(second.terminal))
        firstHost.observeFocus(); secondHost.observeFocus()
        XCTAssertTrue(model.selectedSession === second)
        // 查找框也是该窗格的一部分；模型更新不能把键盘抢回远端终端。
        let searchField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        first.terminal.addSubview(searchField)
        XCTAssertTrue(window.makeFirstResponder(searchField))
        firstHost.observeFocus(); secondHost.observeFocus()
        XCTAssertTrue(model.selectedSession === first)
        firstHost.setFocused(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(window.firstResponder === first.terminal)
        window.contentView = nil
        window.close()
    }

    @MainActor
    func testThemeAndFontApplyToExistingAndNewSessionsWithoutReplacingTerminal() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(store: ConnectionStore(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: TerminalSettingsStore(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let first = model.connect(.init(name: "A", host: "example.test")), terminal = model.selectedSession!.terminal
        XCTAssertEqual(first.terminal.font.pointSize, 16, "首次启动的默认字号应为16pt")
        first.changeFontSize(by: 2)
        first.resetFontSize()
        XCTAssertEqual(first.terminal.font.pointSize, 16, "恢复默认字号应使用16pt")
        var settings = TerminalPreferences()
        settings.theme = .light
        settings.fontSize = 19
        try model.savePreferences(settings)
        XCTAssertTrue(first.terminal === terminal)
        XCTAssertEqual(first.terminal.font.pointSize, 19)
        XCTAssertEqual(first.terminal.nativeBackgroundColor, TerminalTheme.light.background)
        first.changeFontSize(by: 2)
        first.resetFontSize()
        XCTAssertEqual(first.terminal.font.pointSize, 19)
        let next = model.connect(.init(name: "B", host: "example.test"))
        XCTAssertEqual(next.terminal.font.pointSize, 19)
        XCTAssertEqual(next.terminal.nativeBackgroundColor, TerminalTheme.light.background)
    }

    @MainActor
    func testMidnightBlueAppliesAcrossThemesAndResizingWithoutResettingUnchangedPreferences() throws {
        let session = TerminalSession(profile: .init(name: "Palette", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        let terminal = session.terminal
        let sink = PaletteReplyCapture()
        terminal.terminalDelegate = sink
        let standard = TerminalView(frame: .zero)
        standard.nativeBackgroundColor = TerminalTheme.midnight.background
        standard.nativeForegroundColor = TerminalTheme.midnight.foreground
        standard.terminalDelegate = sink
        let originalBlue = try sink.color(4, in: standard)
        let originalBrightBlue = try sink.color(12, in: standard)
        let blue = try sink.color(4, in: terminal)
        let brightBlue = try sink.color(12, in: terminal)
        XCTAssertNotEqual(blue, originalBlue)
        XCTAssertNotEqual(brightBlue, originalBrightBlue)
        XCTAssertGreaterThan(blue.green, 160 * 257)
        for index in [1, 16, 231, 255] {
            XCTAssertEqual(try sink.color(index, in: terminal), try sink.color(index, in: standard))
        }
        var preferences = TerminalPreferences()
        for theme in [TerminalTheme.light, .solarized] {
            preferences.theme = theme
            session.applyPreferences(preferences)
            XCTAssertEqual(try sink.color(4, in: terminal), originalBlue)
            XCTAssertEqual(try sink.color(12, in: terminal), originalBrightBlue)
        }
        preferences.theme = .midnight
        session.applyPreferences(preferences)
        XCTAssertTrue(session.terminal === terminal)
        XCTAssertEqual(try sink.color(4, in: terminal), blue)
        terminal.feed(text: "\u{1b}]4;4;#112233\u{7}")
        let remoteOverride = try sink.color(4, in: terminal)
        session.applyPreferences(preferences)
        XCTAssertEqual(try sink.color(4, in: terminal), remoteOverride)
        preferences.fontSize = 20
        session.applyPreferences(preferences)
        // SwiftTerm改变字号会softReset；恢复的默认蓝色必须仍是当前主题。
        XCTAssertEqual(try sink.color(4, in: terminal), blue)
        let next = TerminalSession(profile: .init(name: "Next", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        next.terminal.terminalDelegate = sink
        XCTAssertEqual(try sink.color(4, in: next.terminal), blue)
        XCTAssertEqual(try sink.color(4, in: standard), originalBlue)
    }

    @MainActor
    func testSearchUsesScrollbackAndKeepsTerminalOutputUnchanged() async throws {
        let session = TerminalSession(profile: .init(name: "Test", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        session.dataReceived(slice: Array("中文 alpha\r\n中文 Alpha\r\n".utf8)[...])
        let before = session.terminal.getTerminal().getBufferAsData()
        session.showFind()
        XCTAssertTrue(session.searchVisible)
        session.searchText = "中文"
        XCTAssertEqual(session.terminal.searchMatchSummary("中文").total, 2)
        XCTAssertTrue(session.searchSummary.contains("2"))
        session.showFind(.next)
        session.showFind(.previous)
        session.searchOptions.caseSensitive = true
        session.searchText = "alpha"
        XCTAssertEqual(session.terminal.searchMatchSummary("alpha", options: SearchOptions(caseSensitive: true)).total, 1)
        session.searchText = "没有这段文字"
        XCTAssertEqual(session.searchSummary, "无匹配")
        session.searchOptions.regex = true
        session.searchText = "["
        XCTAssertEqual(session.searchSummary, "正则表达式无效")
        session.closeSearch()
        XCTAssertFalse(session.searchVisible)
        XCTAssertEqual(session.searchSummary, "")
        session.searchOptions.regex = false
        session.searchText = "中文"
        session.closeSearch()
        session.showFind()
        XCTAssertTrue(session.searchSummary.contains("2"))
        XCTAssertEqual(session.terminal.getTerminal().getBufferAsData(), before)
        XCTAssertNil(session.process)
    }

    func testOutputLogStripsSplitANSIAndPreservesSplitUTF8() throws {
        let file = try temporaryDirectory().appendingPathComponent("output.log")
        let log = try TerminalOutputLog(fileURL: file)
        let chunks: [[UInt8]] = [[0xe4], [0xb8, 0xad, 0xe6], [0x96, 0x87], Array("\u{1b}[31".utf8),
                                Array("m红色\u{1b}[0m\r\n\u{1b}]7;hidden".utf8), [0x1b],
                                Array("\\end\u{1b}Psecret\u{1b}\\!\n".utf8)]
        for chunk in chunks { try log.append(chunk[...]) }
        try log.close()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "中文红色\r\nend!\n")
        XCTAssertThrowsError(try log.append(Array("STOPPED".utf8)[...]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "中文红色\r\nend!\n")
        XCTAssertThrowsError(try TerminalOutputLog(fileURL: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "中文红色\r\nend!\n")
    }

    func testOutputLogPropagatesRealWriteFailure() throws {
        let file = try temporaryDirectory().appendingPathComponent("read-only.log")
        try Data().write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        let log = TerminalOutputLog(handle: handle)
        XCTAssertThrowsError(try log.append(Array("cannot write".utf8)[...]))
        try? log.close()
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
    }

    func testANSICancelAndSubstituteResumeTextAcrossChunks() throws {
        for prefix in ["\u{1b}]0;title", "\u{1b}[31", "\u{1b}Ppayload"] {
            for cancellation: UInt8 in [0x18, 0x1a] {
                let file = try temporaryDirectory().appendingPathComponent("cancelled-sequence.log")
                let log = try TerminalOutputLog(fileURL: file)
                try log.append(Array(prefix.utf8)[...])
                try log.append([cancellation][...])
                try log.append(Array("VISIBLE\n".utf8)[...])
                try log.close()
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "VISIBLE\n")
            }
        }
    }

    @MainActor
    func testLoggingDefaultsOffAndCannotStartBeforeAuthentication() async throws {
        let file = try temporaryDirectory().appendingPathComponent("session.log")
        let session = TerminalSession(profile: .init(name: "Test", host: "example.test"), directoryBookmarks: self.makeTestDirectoryBookmarks())
        XCTAssertNil(session.logURL)
        session.dataReceived(slice: Array("Password: ".utf8)[...])
        XCTAssertThrowsError(try session.startLogging(to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("Password:"))
    }
}
