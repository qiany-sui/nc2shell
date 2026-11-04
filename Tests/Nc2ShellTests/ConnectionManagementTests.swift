import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class ConnectionManagementTests: XCTestCase {
    @MainActor
    func testRememberingReplacementPasswordUpdatesExistingSessionsOnlyAfterSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryCredentials()
        let store = ConnectionStore(fileURL: root.appendingPathComponent("connections.json"))
        let model = AppModel(store: store, settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             credentials: credentials, sessionFactory: { profile in
            TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in
                throw ProfileError("隔离测试不启动网络")
            }
        })
        var profile = ConnectionProfile(name: "Password switch", host: "example.test", username: "test")
        let other = ConnectionProfile(name: "Other", host: "example.test", username: "test")
        model.save(profile, password: "old-fixture")
        model.save(other, password: "other-fixture")
        let first = model.connect(profile), second = model.connect(profile), unrelated = model.connect(other)
        let original = try Data(contentsOf: store.fileURL)
        profile.rememberPassword = true
        try Data("corrupt".utf8).write(to: store.fileURL)
        model.save(profile, password: "new-fixture")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(first.temporaryPassword, "old-fixture")
        XCTAssertNil(try credentials.password(for: profile))

        try original.write(to: store.fileURL)
        model.errorMessage = nil
        model.save(profile, password: "new-fixture")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(first.temporaryPassword, "new-fixture")
        XCTAssertEqual(second.temporaryPassword, "new-fixture")
        XCTAssertEqual(unrelated.temporaryPassword, "other-fixture")
        XCTAssertFalse(model.hasTemporaryPassword(for: profile))
        XCTAssertEqual(try credentials.password(for: profile), "new-fixture")
        let remembered = model.connect(profile)
        XCTAssertNil(remembered.temporaryPassword)
        model.save(profile, password: "latest-fixture")
        XCTAssertEqual(first.temporaryPassword, "latest-fixture")
        XCTAssertEqual(second.temporaryPassword, "latest-fixture")
        XCTAssertNil(remembered.temporaryPassword, "原本使用钥匙串的标签继续按实际提示读取凭据")
    }

    @MainActor
    func testCloseConnectionsMatchesProfileIDAndRemovesAllTabsAndPanes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConnectionStore(fileURL: root.appendingPathComponent("connections.json"))
        let model = AppModel(store: store, settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let profile = ConnectionProfile(name: "同名连接", host: "same.test")
        let other = ConnectionProfile(name: "同名连接", host: "same.test")
        model.save(profile); model.save(other)
        _ = model.connect(profile)
        _ = model.split(.columns)
        _ = model.connect(profile)
        let survivor = model.connect(other)
        XCTAssertEqual(model.sessions.count, 4)
        model.closeConnections(profile) { _, _, _ in XCTFail("已结束的会话无需中断确认"); return false }
        XCTAssertEqual(model.sessions.map(\.id), [survivor.id])
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.selectedSession?.id, survivor.id)
        XCTAssertEqual(try store.load(), [profile, other])
        model.closeConnections(profile) { _, _, _ in XCTFail("无会话时不弹框"); return false }
        XCTAssertTrue(model.selectedSession === survivor)
    }

    @MainActor
    func testDefaultAuthForChangedAccountDoesNotClearOldSessionCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        var profile = ConnectionProfile(name: "Test", host: "old.example.test", username: "nc")
        model.save(profile, password: "old-account-fixture")
        let oldSession = model.connect(profile)
        profile.host = "new.example.test"
        model.save(profile, clearTemporaryPassword: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(oldSession.temporaryPassword, "old-account-fixture")
        XCTAssertFalse(model.hasTemporaryPassword(for: profile))
    }

    @MainActor
    func testSwitchingToSSHDefaultsClearsTemporaryPasswordOnlyAfterSuccessfulSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConnectionStore(fileURL: root.appendingPathComponent("connections.json"))
        let model = AppModel(store: store, settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { profile in TerminalSession(profile: profile, directoryBookmarks: self.makeTestDirectoryBookmarks()) { _, _ in throw ProfileError("隔离测试不启动网络") } })
        let profile = ConnectionProfile(name: "Test", host: "server", username: "nc")
        model.save(profile, password: "temporary-fixture")
        XCTAssertTrue(model.hasTemporaryPassword(for: profile))
        let session = model.connect(profile)
        XCTAssertEqual(session.temporaryPassword, "temporary-fixture")
        model.save(profile)
        XCTAssertTrue(model.hasTemporaryPassword(for: profile), "原有留空保留语义不变")
        let original = try Data(contentsOf: store.fileURL)
        try Data("broken".utf8).write(to: store.fileURL)
        model.save(profile, clearTemporaryPassword: true)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.hasTemporaryPassword(for: profile))
        XCTAssertEqual(session.temporaryPassword, "temporary-fixture")
        try original.write(to: store.fileURL)
        model.errorMessage = nil
        model.save(profile, clearTemporaryPassword: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.hasTemporaryPassword(for: profile))
        XCTAssertNil(session.temporaryPassword, "已有同账户标签的下次重连不能复用被移除的临时密码")
        XCTAssertNil(model.connect(profile).temporaryPassword)
        XCTAssertEqual(try store.load(), [profile])
    }

    @MainActor
    func testSSHDefaultSubmissionClearsStoredPasswordWithoutChangingOtherConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryCredentials()
        let store = ConnectionStore(fileURL: root.appendingPathComponent("connections.json"))
        let model = AppModel(store: store, settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), credentials: credentials,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let profile = ConnectionProfile(name: "Test", host: "server", username: "nc", identityFile: "/tmp/key", rememberPassword: true)
        let other = ConnectionProfile(name: "Other", host: "other", username: "nc", rememberPassword: true)
        model.save(profile, password: "stored-fixture")
        model.save(other, password: "other-fixture")
        let submission = ConnectionAuthenticationChoice.sshDefaults.submission(profile: profile, password: "ignored")
        model.save(submission.profile, password: submission.password, clearTemporaryPassword: submission.clearTemporaryPassword)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(try credentials.password(for: profile))
        XCTAssertEqual(try credentials.password(for: other), "other-fixture")
        XCTAssertEqual(model.profiles.first, submission.profile)
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains("fixture"))
    }

    @MainActor
    func testEnteredPasswordRequiresUsernameAndRejectsInvalidSecretsWithoutSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")),
                             settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")),
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        var profile = ConnectionProfile(name: "Test", host: "host")
        model.editor = profile
        model.save(profile, password: "temporary-fixture")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNotNil(model.editor)
        profile.username = "nc"
        for password in ["line\nbreak", "nul\0byte", String(repeating: "x", count: 1023)] {
            model.errorMessage = nil
            model.save(profile, password: password)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.profiles.isEmpty)
        }
    }

    @MainActor
    func testSaveSearchClearAndAccountChangeNeverReusePassword() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryCredentials()
        let store = ConnectionStore(fileURL: root.appendingPathComponent("connections.json"))
        let model = AppModel(store: store, settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), credentials: credentials,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        var profile = ConnectionProfile(name: "开发 数据库", host: "db.example.test", username: "Alice", rememberPassword: true)
        model.save(profile, password: "isolated-fixture")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains("isolated-fixture"))
        for query in ["开发", "DB.EXAMPLE", " alice "] {
            model.connectionQuery = query
            XCTAssertEqual(model.filteredProfiles, [profile])
        }
        model.connectionQuery = "absent"
        XCTAssertTrue(model.filteredProfiles.isEmpty)
        let old = profile
        profile.host = "other.test"
        model.save(profile)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.profiles, [old])
        model.errorMessage = nil
        model.save(profile, password: "replacement-fixture")
        XCTAssertNil(try credentials.password(for: old))
        XCTAssertEqual(try credentials.password(for: profile), "replacement-fixture")
        profile.rememberPassword = false
        model.save(profile)
        XCTAssertNil(try credentials.password(for: profile))
        model.save(profile, password: nil)
        model.deleteConfirmed(profile)
        XCTAssertTrue(try store.load().isEmpty)
    }

    @MainActor
    func testKeychainFailureDoesNotSaveOrDismissEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryCredentials()
        credentials.rejectWrites = true
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), credentials: credentials,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        let profile = ConnectionProfile(name: "Test", host: "host", username: "nc", rememberPassword: true)
        model.editor = profile
        model.save(profile, password: "fixture")
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(model.editor)
    }

    @MainActor
    func testRenamingPreservesPasswordButPortOrAccountChangeRequiresNewPasswordAndDeleteClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryCredentials()
        let model = AppModel(store: .init(fileURL: root.appendingPathComponent("connections.json")), settingsStore: .init(fileURL: root.appendingPathComponent("settings.json")), credentials: credentials,
                             sessionFactory: { TerminalSession(profile: $0, directoryBookmarks: self.makeTestDirectoryBookmarks()) })
        var profile = ConnectionProfile(name: "Original", host: "host", username: "nc", rememberPassword: true)
        model.save(profile, password: "fixture-password")
        profile.name = "Renamed"
        model.save(profile)
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertNil(model.errorMessage)
        for changeUser in [false, true] {
            var changed = profile
            if changeUser { changed.username = "other" } else { changed.port = 2222 }
            model.save(changed)
            XCTAssertEqual(model.profiles, [profile])
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNil(try credentials.password(for: changed))
            model.errorMessage = nil
        }
        model.deleteConfirmed(profile)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNil(try credentials.password(for: profile))
    }

    func testAskpassRecognizesOnlyClientAccountPasswordPrompt() {
        XCTAssertTrue(SSHAskpass.isAccountPasswordPrompt("nc@server's password: ", username: "nc"))
        for prompt in ["Password:", "Verification code: ", "other@server's password: ", "Enter passphrase for key 'nc@server': ", "Enter nc@server's old password: ", "nc@server's password: \n"] {
            XCTAssertFalse(SSHAskpass.isAccountPasswordPrompt(prompt, username: "nc"))
        }
    }
}

private final class MemoryCredentials: ConnectionCredentials {
    var values: [String: String] = [:]
    var rejectWrites = false
    private func key(_ profile: ConnectionProfile) -> String { "\(profile.id)|\(profile.host)|\(profile.port)|\(profile.username)" }
    func password(for profile: ConnectionProfile) throws -> String? { values[key(profile)] }
    func setPassword(_ password: String?, for profile: ConnectionProfile) throws {
        if rejectWrites { throw ProfileError("测试钥匙串拒绝写入") }
        values[key(profile)] = password
    }
}
