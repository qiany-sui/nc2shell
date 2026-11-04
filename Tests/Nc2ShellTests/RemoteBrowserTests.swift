import XCTest
import Nc2ShellCore
@testable import Nc2Shell

final class RemoteBrowserTests: XCTestCase {
    @MainActor
    func testHeaderSortSwitchesFieldThenDirectionWithoutChangingFilterOrSelection() {
        let browser = RemoteBrowserState()
        let files = [RemoteFile(name: "folder", size: 999, mode: 0o040755),
                     RemoteFile(name: "small.txt", size: 2, mode: 0o100644),
                     RemoteFile(name: "large.txt", size: 20, mode: 0o100644),
                     RemoteFile(name: "unknown.txt", size: 0, mode: 0o100644, hasSize: false)]
        browser.query = "txt"
        browser.sortBy(.size)
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["small.txt", "large.txt", "unknown.txt"])
        browser.sortBy(.size)
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["large.txt", "small.txt", "unknown.txt"])
        XCTAssertEqual(browser.selectedFiles(files, selection: ["small.txt", "large.txt"]).map(\.name), ["large.txt", "small.txt"])
        browser.query = ""
        browser.sortBy(.name)
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder", "large.txt", "small.txt", "unknown.txt"])
        browser.sortBy(.name)
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder", "unknown.txt", "small.txt", "large.txt"])
    }

    @MainActor
    func testFilterHidesUnselectedNamesAndOnlyVisibleSelectionCanBeActedOn() {
        let browser = RemoteBrowserState()
        let files = [RemoteFile(name: ".env", size: 12, mode: 0o100600),
                     RemoteFile(name: "报告.TXT", size: 40, mode: 0o100644),
                     RemoteFile(name: "notes.txt", size: 10, mode: 0o100644)]
        XCTAssertEqual(Set(browser.visibleFiles(files).map(\.name)), ["notes.txt", "报告.TXT"])
        browser.query = "TXT"
        XCTAssertEqual(browser.selectedFiles(files, selection: [".env", "notes.txt"]).map(\.name), ["notes.txt"])
        browser.query = "报告"
        XCTAssertEqual(browser.selectedFiles(files, selection: [".env", "notes.txt"]), [])
        browser.query = ""
        browser.showHidden = true
        XCTAssertTrue(browser.visibleFiles(files).contains { $0.name == ".env" })
    }

    @MainActor
    func testSortIsNaturalWithDirectoriesFirstAndUnknownDatesLast() {
        let browser = RemoteBrowserState()
        let files = [RemoteFile(name: "file10", size: 10, mode: 0o100644, modifiedTime: 20),
                     RemoteFile(name: "folder", size: 999, mode: 0o040755, modifiedTime: 40),
                     RemoteFile(name: "file2", size: 20, mode: 0o100644, modifiedTime: 0),
                     RemoteFile(name: "unknown", size: 1, mode: 0o100644)]
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder", "file2", "file10", "unknown"])
        browser.sortField = .size
        browser.ascending = false
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder", "file2", "file10", "unknown"])
        browser.sortField = .modified
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder", "file10", "file2", "unknown"])
        browser.ascending = true
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder", "file2", "file10", "unknown"])
    }

    @MainActor
    func testModifiedTimeSortAlsoOrdersTheDirectoryGroup() {
        let browser = RemoteBrowserState()
        browser.sortField = .modified
        let files = [RemoteFile(name: "folder-a", size: 0, mode: 0o040755, modifiedTime: 200),
                     RemoteFile(name: "folder-z", size: 0, mode: 0o040755, modifiedTime: 100),
                     RemoteFile(name: "file", size: 1, mode: 0o100644, modifiedTime: 50)]
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder-z", "folder-a", "file"])
        browser.ascending = false
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["folder-a", "folder-z", "file"])
    }

    @MainActor
    func testUnknownSizeIsNotSortedAsAnEmptyFile() {
        let browser = RemoteBrowserState()
        browser.sortField = .size
        let files = [RemoteFile(name: "missing", size: 0, mode: 0o100644, hasSize: false),
                     RemoteFile(name: "empty", size: 0, mode: 0o100644),
                     RemoteFile(name: "large", size: 9, mode: 0o100644)]
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["empty", "large", "missing"])
        browser.ascending = false
        XCTAssertEqual(browser.visibleFiles(files).map(\.name), ["large", "empty", "missing"])
    }

    @MainActor
    func testPropertiesKeepMissingAttributesUnknownAndShowSpecialPermissionBits() {
        let file = RemoteFile(name: "a '文件.txt", size: 12, mode: 0o104755)
        XCTAssertEqual(RemoteBrowserState.permissions(file), "-rwsr-xr-x (4755)")
        XCTAssertEqual(RemoteBrowserState.permissions(.init(name: "unknown", size: 0, mode: 0)), "未知")
        XCTAssertEqual(RemoteBrowserState.modified(file), "未知")
        XCTAssertEqual(RemoteBrowserState.paths([file], in: "/test dir"), "/test dir/a '文件.txt")
        XCTAssertEqual(RemoteBrowserState.paths([file], in: "/"), "/a '文件.txt")
    }
}
