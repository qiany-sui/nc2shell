import Foundation

public struct TransferConflict: Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let sourceIsDirectory: Bool
    public let destinationIsDirectory: Bool
    public let canKeepBoth: Bool

    public init(sourcePath: String, destinationPath: String, sourceIsDirectory: Bool,
                destinationIsDirectory: Bool, canKeepBoth: Bool) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceIsDirectory = sourceIsDirectory
        self.destinationIsDirectory = destinationIsDirectory
        self.canKeepBoth = canKeepBoth
    }
}

public enum TransferConflictChoice: Sendable {
    case replace, skip, keepBoth, merge, cancel
}

public typealias TransferConflictResolver = @Sendable (TransferConflict) async throws -> TransferConflictChoice

public struct TransferResult: Sendable {
    public let bytes: UInt64
    public let skippedCount: Int

    public init(bytes: UInt64, skippedCount: Int) {
        self.bytes = bytes
        self.skippedCount = skippedCount
    }
}
