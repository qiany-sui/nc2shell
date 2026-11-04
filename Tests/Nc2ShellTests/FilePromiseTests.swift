import XCTest
import AppKit
import UniformTypeIdentifiers
import Nc2ShellCore
@testable import Nc2Shell

final class FilePromiseTests: XCTestCase {
    @MainActor
    func testPromisePreservesFilenameAndKeepsItsDelegateAlive() {
        let model = RemoteFilesModel()
        for mode: UInt32 in [0o100600, 0o040700] {
            let file = RemoteFile(name: "中文 空格 #.txt", size: 3, mode: mode)
            let promise: NSFilePromiseProvider = RemoteDownloadPromise(file: file, directory: "/remote", connectionID: model.connectionID, model: model)
            XCTAssertEqual(promise.fileType, mode == 0o040700 ? UTType.folder.identifier : UTType.data.identifier)
            XCTAssertTrue(promise.delegate === promise)
            XCTAssertEqual(promise.delegate?.filePromiseProvider(promise, fileNameForType: promise.fileType), "中文 空格 #.txt")
            XCTAssertFalse(model.isTransferring, "起拖仅发布承诺，不能提前下载")
        }
    }

    @MainActor
    func testDisconnectedModelRejectsPromiseAndCompletesDownloadFailureOnce() {
        let model = RemoteFilesModel(), file = RemoteFile(name: "file", size: 1, mode: 0o100600)
        XCTAssertNil(model.promiseProvider(for: file))
        var calls = 0
        model.download(file, to: URL(fileURLWithPath: "/tmp/not-written"), expectedPath: "/remote", connectionID: model.connectionID, revision: model.locationRevision) { error in
            calls += 1
            XCTAssertNotNil(error)
        }
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testPromiseWithReleasedModelFinishesWithError() async {
        var model: RemoteFilesModel? = RemoteFilesModel()
        let file = RemoteFile(name: "file", size: 1, mode: 0o100600)
        let promise = RemoteDownloadPromise(file: file, directory: "/remote", connectionID: model!.connectionID, model: model!)
        weak let weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        let finished = expectation(description: "已关闭会话的文件承诺必须结束")
        promise.filePromiseProvider(promise, writePromiseTo: URL(fileURLWithPath: "/tmp/not-written")) { error in
            XCTAssertNotNil(error)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
    }
}
