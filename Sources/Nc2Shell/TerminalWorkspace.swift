import Foundation

enum TerminalSplitAxis { case columns, rows }

struct TerminalWorkspace: Identifiable {
    let id = UUID()
    let tabNumber: Int
    var primarySessionID: UUID
    var secondarySessionID: UUID?
    var focusedSessionID: UUID
    var axis: TerminalSplitAxis = .rows
    var splitFraction: Double = 0.5
    var sessionIDs: [UUID] { [primarySessionID] + (secondarySessionID.map { [$0] } ?? []) }

    init(sessionID: UUID, tabNumber: Int = 1) {
        self.tabNumber = tabNumber
        primarySessionID = sessionID
        focusedSessionID = sessionID
    }
}
