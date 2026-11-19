import Foundation

/// One of the phone app's tabs, each with its own stack (SceneController), as
/// Rails lists them in the path configuration's settings
/// (PathConfiguration::TABS): renaming or moving a tab needs no new build.
/// Agents is the web's own first page, where most time is spent; Needs you
/// every card waiting on the person, with their count as its badge
/// (TabBadgeComponent); Settings the web's own list of settings (/settings),
/// each place on it a sheet (PathConfiguration ios_v3).
struct AppTab: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    /// An SF Symbol, filled when selected, as the system's own apps do.
    let image: String
    /// The tab's first page, a path on this install.
    let path: String

    private enum CodingKeys: String, CodingKey {
        case id, title
        case image = "ios_image"
        case path = "url"
    }

    func url(base: URL) -> URL {
        path == "/" ? base : base.appending(path: String(path.dropFirst()))
    }

    /// The tabs in the path configuration Hotwire Native has loaded: the
    /// bundled copy at launch, or the install's own, cached from the last
    /// launch. Without tabs it can read, an older configuration's say, the
    /// app's own list, the same as Rails serves today.
    static func served(_ settings: [String: AnyHashable]) -> [AppTab] {
        // An object JSONSerialization can't write raises rather than throws: ask first.
        guard let tabs = settings["tabs"]?.base, JSONSerialization.isValidJSONObject(tabs),
              let json = try? JSONSerialization.data(withJSONObject: tabs),
              let decoded = try? JSONDecoder().decode([AppTab].self, from: json),
              !decoded.isEmpty else { return fallback }
        return decoded
    }

    static let fallback = [
        AppTab(id: "agents", title: "Agents", image: "bubble.left.and.bubble.right", path: "/"),
        AppTab(id: "needs-you", title: "Needs you", image: "hand.raised", path: "/approvals"),
        AppTab(id: "settings", title: "Settings", image: "gearshape", path: "/settings")
    ]
}

extension Array where Element == AppTab {
    /// The tab a page belongs in, when a notification opens it: the one whose
    /// first page it is, or is under (a card under Needs you); anything else
    /// in the first tab.
    func holding(_ path: String) -> AppTab {
        let under = filter { $0.path != "/" && (path == $0.path || path.hasPrefix($0.path + "/")) }
        return under.max { $0.path.count < $1.path.count } ?? self[0]
    }
}
