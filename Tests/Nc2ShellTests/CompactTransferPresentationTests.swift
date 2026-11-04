import XCTest
@testable import Nc2Shell

final class CompactTransferPresentationTests: XCTestCase {
    @MainActor
    func testGenericProgressKeepsTransferNameVisible() {
        let item = TransferQueueItem(connectionID: UUID(), name: "项目归档", direction: .upload,
                                     source: "/local/项目归档", target: "/remote/项目归档", isFilePromise: false)
        // 估算大目录，以及并发回落单任务时都可能只有通用状态，仍需认清取消对象。
        for summary in ["正在统计传输大小…", "正在上传…"] {
            let view = CompactTransferView(item: item, model: RemoteFilesModel(), summary: summary, showTransfers: {})
            XCTAssertEqual(view.title, "项目归档")
            XCTAssertEqual(view.subtitle, summary)
        }
    }

    @MainActor
    func testSingleItemProgressDoesNotRepeatFileName() {
        let item = TransferQueueItem(connectionID: UUID(), name: "release.zip", direction: .upload,
                                     source: "/local/release.zip", target: "/remote/release.zip", isFilePromise: false)
        let view = CompactTransferView(item: item, model: RemoteFilesModel(),
                                       summary: "正在处理 1/1：release.zip…", showTransfers: {})
        XCTAssertEqual(view.title, "release.zip")
        XCTAssertEqual(view.subtitle, "上传 · 1/1")
    }

    @MainActor
    func testBatchProgressAndSpecialFileNamesRemainIdentifiable() {
        let item = TransferQueueItem(connectionID: UUID(), name: "下载 3 项", direction: .download,
                                     source: "/remote", target: "/local", isFilePromise: false)
        let view = CompactTransferView(item: item, model: RemoteFilesModel(),
                                       summary: "正在下载 2/3：报告：最终版….txt…", showTransfers: {})
        XCTAssertEqual(view.title, "报告：最终版….txt")
        XCTAssertEqual(view.subtitle, "下载 · 2/3")
        let unrelated = CompactTransferView(item: item, model: RemoteFilesModel(),
                                            summary: "准备中：等待可用通道…", showTransfers: {})
        XCTAssertEqual(unrelated.title, "下载 3 项")
        XCTAssertEqual(unrelated.subtitle, "准备中：等待可用通道…")
    }

    @MainActor
    func testMissingSummaryKeepsNameAndTransferDirection() {
        let item = TransferQueueItem(connectionID: UUID(), name: "release.zip", direction: .download,
                                     source: "/remote/release.zip", target: "/local/release.zip", isFilePromise: false)
        let view = CompactTransferView(item: item, model: RemoteFilesModel(), summary: nil, showTransfers: {})
        XCTAssertEqual(view.title, "release.zip")
        XCTAssertEqual(view.subtitle, "下载")
    }
}
