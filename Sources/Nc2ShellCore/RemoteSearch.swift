import Foundation

public struct RemoteSearchMatch: Identifiable, Equatable {
    public let path: String
    public let file: RemoteFile
    public var id: String { path }
}

public struct RemoteSearchIssue: Equatable {
    public let path: String
    public let reason: String
}

public struct RemoteSearchSnapshot: Equatable {
    public internal(set) var matches: [RemoteSearchMatch] = []
    public internal(set) var scannedCount = 0
    public internal(set) var currentDirectory = ""
    public internal(set) var skippedCount = 0
    public internal(set) var issues: [RemoteSearchIssue] = []
    public internal(set) var truncated = false

    public init() {}
}
