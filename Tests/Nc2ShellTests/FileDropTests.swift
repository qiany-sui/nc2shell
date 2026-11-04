import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Nc2Shell

final class FileDropTests: XCTestCase {
    @MainActor
    func testReadsFileAndFolderURLsInOriginalDropOrder() async throws {
        let file = URL(fileURLWithPath: "/tmp/中文 空格 #.txt")
        let folder = URL(fileURLWithPath: "/tmp/My Folder", isDirectory: true)
        let finished = expectation(description: "读取全部拖入项目")
        LocalFileDrop.load([fileDropProvider(file, delay: 0.1), NSItemProvider(object: folder as NSURL)]) { result in
            switch result {
            case .success(let urls): XCTAssertEqual(urls, [file, folder])
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
    }

    @MainActor
    func testRejectsNonFileURLsMalformedDataAndMixedFailedBatch() async {
        let badProviders = [NSItemProvider(object: "text" as NSString),
                            fileDropDataProvider(Data("https://example.com/a.txt".utf8)),
                            fileDropDataProvider(Data("file://another-host/share/file".utf8)),
                            fileDropDataProvider(Data([0xff, 0x00])),
                            fileDropDataProvider(nil)]
        for bad in badProviders {
            let finished = expectation(description: "无效拖入整批拒绝")
            LocalFileDrop.load([NSItemProvider(object: URL(fileURLWithPath: "/tmp/valid") as NSURL), bad]) { result in
                if case .success = result { XCTFail("无效拖入不能部分成功") }
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 3)
        }
    }

    @MainActor
    func testDisconnectedPanelRejectsDropImmediately() {
        let model = RemoteFilesModel()
        XCTAssertFalse(model.uploadDroppedItems([fileDropProvider(URL(fileURLWithPath: "/tmp/file"))]))
        XCTAssertFalse(model.isPreparingUpload)
        XCTAssertFalse(model.isTransferring)
    }
}

func fileDropProvider(_ url: URL, delay: TimeInterval = 0) -> NSItemProvider {
    fileDropDataProvider(url.dataRepresentation, delay: delay)
}

func fileDropDataProvider(_ data: Data?, delay: TimeInterval = 0) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { complete in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            complete(data, data == nil ? NSError(domain: "DropFixture", code: 1) : nil)
        }
        return nil
    }
    return provider
}
