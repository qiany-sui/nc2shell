import AppKit
import SwiftUI
import XCTest
import Nc2ShellCore
@testable import Nc2Shell

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testSettingsUsesMainWindowSheetAndDismissesWithoutSaving() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nc2-sheet-window-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = TerminalSettingsStore(fileURL: root.appendingPathComponent("terminal.json"))
        let transfer = TransferPreferencesStore(fileURL: root.appendingPathComponent("transfer.json"))
        let controller = TransferSettingsController(store: transfer)
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: terminal, transferSettings: controller,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        model.showSettings()
        for _ in 0..<40 {
            if NSApp.windows.contains(where: { $0.sheetParent === window && $0.isVisible }) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        // SwiftUI 自己的 SheetPresentationWindow 不列入 NSWindow.sheets，以实际父窗口关联验证。
        let sheet = try XCTUnwrap(NSApp.windows.first { $0.sheetParent === window && $0.isVisible })
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        sheet.sendEvent(escape)
        for _ in 0..<40 {
            if !model.settingsPresented { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(model.settingsPresented, "Esc 应等同取消并结束编辑")
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.fileURL.path))
    }
}
