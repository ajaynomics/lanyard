import Foundation

/// What a page sends the app's tab-badge component (layouts/_badge): how many
/// cards wait on the person, and the id of the tab that shows them, one of
/// the tabs Rails serves (AppTab).
struct TabBadge: Decodable, Equatable {
    let count: Int
    let tab: String

    /// No badge at all, rather than a zero.
    var text: String? { count > 0 ? String(count) : nil }

    /// Where its tab is among these, for tab bars before iOS 18's UITab.
    func index(in tabs: [AppTab]) -> Int? {
        tabs.firstIndex { $0.id == tab }
    }
}
