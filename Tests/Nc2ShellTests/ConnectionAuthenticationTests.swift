import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class ConnectionAuthenticationTests: XCTestCase {
    func testExistingConfigurationSelectsPrivateKeyBeforePasswordAndKeepsDefaultsDistinct() {
        var profile = ConnectionProfile(name: "Test", host: "server")
        XCTAssertEqual(ConnectionAuthenticationChoice.initial(profile: profile, hasTemporaryPassword: false), .sshDefaults)
        XCTAssertEqual(ConnectionAuthenticationChoice.initial(profile: profile, hasTemporaryPassword: true), .password)
        profile.rememberPassword = true
        XCTAssertEqual(ConnectionAuthenticationChoice.initial(profile: profile, hasTemporaryPassword: false), .password)
        profile.identityFile = "/tmp/fixture key"
        XCTAssertEqual(ConnectionAuthenticationChoice.initial(profile: profile, hasTemporaryPassword: true), .privateKey)
        profile.name = ""
        profile.identityFile = ""
        profile.rememberPassword = false
        XCTAssertEqual(ConnectionAuthenticationChoice.initial(profile: profile, hasTemporaryPassword: false), .password)
    }

    func testPasswordChoiceDoesNotSubmitHiddenPrivateKeyAndKeepsBlankPasswordSemantics() {
        let profile = ConnectionProfile(name: "Test", host: "server", username: "nc", identityFile: "/tmp/fixture key", rememberPassword: true)
        let result = ConnectionAuthenticationChoice.password.submission(profile: profile, password: "fixture")
        XCTAssertEqual(result.profile.identityFile, "")
        XCTAssertTrue(result.profile.rememberPassword)
        XCTAssertEqual(result.password, "fixture")
        XCTAssertFalse(result.clearTemporaryPassword)
        XCTAssertNil(ConnectionAuthenticationChoice.password.submission(profile: profile, password: "").password)
        XCTAssertEqual(profile.identityFile, "/tmp/fixture key", "构建提交值不改变切回时的原草稿")
    }

    func testPrivateKeyChoiceRetainsOptionalAccountPassword() {
        let profile = ConnectionProfile(name: "Test", host: "server", username: "nc", identityFile: "/tmp/中文 key", rememberPassword: true)
        let result = ConnectionAuthenticationChoice.privateKey.submission(profile: profile, password: "fixture")
        XCTAssertEqual(result.profile, profile)
        XCTAssertEqual(result.password, "fixture")
        XCTAssertFalse(result.clearTemporaryPassword)
    }

    func testSSHDefaultsNeverSubmitHiddenCredentials() {
        let profile = ConnectionProfile(name: "Test", host: "server", identityFile: "/tmp/key", rememberPassword: true)
        let result = ConnectionAuthenticationChoice.sshDefaults.submission(profile: profile, password: "hidden-fixture")
        XCTAssertEqual(result.profile.identityFile, "")
        XCTAssertFalse(result.profile.rememberPassword)
        XCTAssertNil(result.password)
        XCTAssertTrue(result.clearTemporaryPassword)
        XCTAssertNoThrow(try result.profile.validated(), "隐藏的记住密码开关不应使默认SSH要求用户名")
    }
}
