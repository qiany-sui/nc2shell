import XCTest
@testable import Nc2ShellCore

final class AutoReconnectProfileTests: XCTestCase {
    func testAutomaticReconnectSettingSurvivesRoundTripAndOldProfileDefaultsOff() throws {
        let original = ConnectionProfile(name: "配置", host: "example.invalid")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["autoReconnect"] = true
        let enabled = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(enabled)) as? [String: Any])
        XCTAssertEqual(saved["autoReconnect"] as? Bool, true)
        object.removeValue(forKey: "autoReconnect")
        let legacy = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: object))
        let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertEqual(migrated["autoReconnect"] as? Bool, false)
    }
}
