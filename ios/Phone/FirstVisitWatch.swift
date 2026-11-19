import Foundation

/// Whether fresh tabs' first page has come to an end, loaded or failed
/// (SceneController). A page that does neither, as a refused connection to
/// one of the ports WebKit won't use (the M4's port 9) did, would spin
/// forever: overdue, it gets the error screen and Try again. Each start has
/// its own number, so a wait from older tabs never fires on newer ones.
struct FirstVisitWatch {
    static let patience: TimeInterval = 15

    private var current = 0
    private var startedAt: Date?

    /// Fresh tabs, or Try again: starts a wait and returns its number.
    mutating func started(at now: Date) -> Int {
        current += 1
        startedAt = now
        return current
    }

    /// The page loaded or failed: nothing is waited for.
    mutating func settled() {
        startedAt = nil
    }

    /// Whether wait `number` is still the current one and has gone on too long.
    func isOverdue(_ number: Int, at now: Date) -> Bool {
        guard number == current, let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= Self.patience
    }
}
