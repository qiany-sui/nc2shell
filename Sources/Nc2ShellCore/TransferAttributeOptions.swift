import Foundation

public struct TransferAttributeOptions: Codable, Equatable {
    public var preservePermissions: Bool
    public var preserveModificationTime: Bool
    public var isEnabled: Bool { preservePermissions || preserveModificationTime }

    public init(preservePermissions: Bool = false, preserveModificationTime: Bool = false) {
        self.preservePermissions = preservePermissions
        self.preserveModificationTime = preserveModificationTime
    }
}
