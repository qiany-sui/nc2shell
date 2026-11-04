import AppKit
import UniformTypeIdentifiers

@MainActor
enum LocalFileDrop {
    private enum Failure: LocalizedError {
        case invalidFile
        var errorDescription: String? { "只能拖入可读取的本地文件或文件夹。" }
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping (Result<[URL], Error>) -> Void) {
        guard !providers.isEmpty, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            completion(.failure(Failure.invalidFile)); return
        }
        var urls = [URL?](repeating: nil, count: providers.count)
        var remaining = providers.count
        var failure: Error?
        // 必须在放下回调返回前开始读取所有提供者，保留系统对拖放数据的访问授权。
        for (index, provider) in providers.enumerated() {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                DispatchQueue.main.async {
                    if let error { failure = error }
                    else if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL,
                            url.host == nil || url.host == "" || url.host == "localhost" {
                        urls[index] = url
                    } else { failure = Failure.invalidFile }
                    remaining -= 1
                    guard remaining == 0 else { return }
                    if let failure { completion(.failure(failure)) }
                    else { completion(.success(urls.compactMap { $0 })) }
                }
            }
        }
    }
}
