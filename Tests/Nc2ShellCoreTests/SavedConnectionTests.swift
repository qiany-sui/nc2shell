import XCTest
@testable import Nc2ShellCore

final class SavedConnectionTests: XCTestCase {
    func testLegacyProfileExplicitlyDefaultsToNotRememberingPassword() throws {
        let data = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"旧连接","host":"example.test","port":22,"username":"nc","identityFile":""}"#.utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertEqual(object["rememberPassword"] as? Bool, false)
    }

    func testRememberingPasswordRequiresExplicitAccount() throws {
        let data = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"连接","host":"example.test","port":22,"username":"","identityFile":"","rememberPassword":true}"#.utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertThrowsError(try profile.validated())
    }
}
