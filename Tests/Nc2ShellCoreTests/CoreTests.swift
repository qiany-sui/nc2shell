import XCTest
@testable import Nc2ShellCore

final class CoreTests: XCTestCase {
    func testRejectsHostsThatCouldBecomeOptionsOrCommands() {
        for host in ["", " ", "-oProxyCommand=touch", "server\nother", "host;id", "user@host", "ssh://host", "host name"] {
            XCTAssertThrowsError(try ConnectionProfile(name: "Test", host: host).validated(), host)
        }
    }

    func testNormalizesHostAndAcceptsIPv6AndSSHAlias() throws {
        XCTAssertEqual(try ConnectionProfile(name: " Test ", host: " [2001:db8::1] ").validated().host, "2001:db8::1")
        XCTAssertEqual(try ConnectionProfile(name: " Test ", host: "prod-api").validated().name, "Test")
    }

    func testRejectsOutOfRangePortsAndInvalidUsernames() {
        for port in [0, -1, 65536] {
            XCTAssertThrowsError(try ConnectionProfile(name: "Test", host: "server", port: port).validated())
        }
        for username in ["user\nname", "user name"] {
            XCTAssertThrowsError(try ConnectionProfile(name: "Test", host: "server", username: username).validated())
        }
    }

    func testBuildsSeparateArgumentsAndPreservesPrivateKeyPath() throws {
        let profile = ConnectionProfile(name: "Test", host: "server", port: 2222, username: "nc", identityFile: "/tmp/My Keys/id_ed25519")
        let args = try SSHCommand.arguments(profile: profile, controlPath: "/tmp/nc-test/s")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=ask"))
        XCTAssertEqual(Array(args.suffix(3)), ["/tmp/My Keys/id_ed25519", "--", "server"])
        XCTAssertTrue(args.windows(of: 2).contains(["-p", "2222"]))
        XCTAssertTrue(args.windows(of: 2).contains(["-l", "nc"]))
        XCTAssertTrue(args.windows(of: 2).contains(["-S", "/tmp/nc-test/s"]))
    }

    func testEmptyUsernameKeepsSSHConfigUser() throws {
        let args = try SSHCommand.arguments(profile: ConnectionProfile(name: "Test", host: "alias"), controlPath: "/tmp/nc-test/s")
        XCTAssertFalse(args.contains("-l"))
    }

    func testStoreRoundTripAndAtomicReplacement() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConnectionStore(fileURL: root.appendingPathComponent("nested/connections.json"))
        XCTAssertEqual(try store.load(), [])
        let profile = ConnectionProfile(name: "部署机", host: "example.test", username: "nc")
        try store.save([profile])
        XCTAssertEqual(try store.load(), [profile])
        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }

    func testCorruptStoreIsNotOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("connections.json")
        let original = Data("not valid json".utf8)
        try original.write(to: file)
        let store = ConnectionStore(fileURL: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testSavingInvalidProfileDoesNotChangeFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConnectionStore(fileURL: root.appendingPathComponent("connections.json"))
        let original = ConnectionProfile(name: "Test", host: "server")
        try store.save([original])
        XCTAssertThrowsError(try store.save([ConnectionProfile(name: "Bad", host: "-bad")]))
        XCTAssertEqual(try store.load(), [original])
    }

    func testDirectoryReportDecodesUTF8AndSpacesWithoutLosingHost() {
        XCTAssertEqual(RemoteDirectory.parse("file://remote.example/home/nc/My%20Files/%E4%B8%AD%E6%96%87"), RemoteDirectory(host: "remote.example", path: "/home/nc/My Files/中文"))
    }

    func testRejectsAmbiguousAndMalformedDirectoryReports() {
        for report in ["/tmp", "https://host/tmp", "file:///tmp", "file://host/dir?x=1", "file://host/%00tmp", "file://user@host/tmp", "file://host/%ZZ", "file://host/tmp#fragment"] {
            XCTAssertNil(RemoteDirectory.parse(report), report)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nc2shell-test-\(UUID().uuidString)")
    }
}

private extension Array where Element == String {
    func windows(of count: Int) -> [[String]] {
        guard self.count >= count else { return [] }
        return (0...(self.count - count)).map { Array(self[$0..<($0 + count)]) }
    }
}
