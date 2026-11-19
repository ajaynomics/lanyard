import HotwireNative
import UIKit

/// The app's tab bar: Hotwire Native's, one stack per tab Rails serves
/// (AppTab), which keeps those tabs so a page's badge (TabBadgeComponent) and
/// a tapped notification (SceneController) find theirs by id. Only the
/// selected tab loads until another is chosen.
final class AppTabBarController: HotwireTabBarController {
    let served: [AppTab]
    /// Kept, as loaded, to find a tab's stack again (navigator(forTabID:)).
    private let servedTabs: [HotwireTab]

    init(tabs: [AppTab], base: URL, navigatorDelegate: NavigatorDelegate) {
        served = tabs
        servedTabs = tabs.map { tab in
            HotwireTab(id: tab.id, title: tab.title, image: UIImage(systemName: tab.image),
                       selectedImage: UIImage(systemName: tab.image + ".fill"), url: tab.url(base: base))
        }
        super.init(navigatorDelegate: navigatorDelegate, lazyLoadTabs: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Starts the selected tab's first visit, which asks the navigator
    /// delegate at once.
    func loadServedTabs() {
        load(servedTabs)
    }

    /// The stack of the tab with this id, if these tabs have it.
    func navigator(forTabID id: String) -> Navigator? {
        servedTabs.first { $0.id == id }.flatMap { navigator(for: $0) }
    }

    /// Selects the tab with this id. A tab chosen in code is not started by a
    /// tap, so it starts here (a started one ignores this).
    func selectTab(_ tab: AppTab) {
        guard let index = served.firstIndex(of: tab) else { return }
        if #available(iOS 18.0, *) {
            selectedTab = self.tab(forIdentifier: tab.id)
        } else {
            selectedIndex = index
        }
        activeNavigator.start()
    }

    func showBadge(_ badge: TabBadge) {
        if #available(iOS 18.0, *) {
            tab(forIdentifier: badge.tab)?.badgeValue = badge.text
        } else if let index = badge.index(in: served), let viewControllers, viewControllers.indices.contains(index) {
            viewControllers[index].tabBarItem.badgeValue = badge.text
        }
    }
}

extension UIViewController {
    /// The app's tabs this page is in, or is a sheet over.
    var hostingTabs: AppTabBarController? {
        (self as? AppTabBarController) ?? (tabBarController as? AppTabBarController) ?? presentingViewController?.hostingTabs
    }
}
