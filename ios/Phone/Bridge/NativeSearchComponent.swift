import HotwireNative
import UIKit

/// The Agents list's search as the bar's own search field: each change
/// replies with the query, which the page types into its own field
/// (web side: app/javascript/native/search_controller.js). Bridge
/// Components' SearchComponent under the app's own name, "native-search":
/// builds already out answer the library's "search", which was never
/// checked here, and the page hides its field only for this name. The
/// library's class is final, so this mirrors it (0.14.0).
final class NativeSearchComponent: BridgeComponent {
    override nonisolated class var name: String { "native-search" }

    private let searchController = UISearchController(searchResultsController: nil)
    private lazy var updater = Updater(component: self)
    private var viewController: UIViewController? { delegate?.destination as? UIViewController }

    override func onReceive(message: Message) {
        guard message.event == "connect", let viewController else { return }
        let data: MessageData? = message.data()
        searchController.searchResultsUpdater = updater
        if let placeholder = data?.placeholder { searchController.searchBar.placeholder = placeholder }
        viewController.navigationItem.searchController = searchController
        viewController.navigationItem.hidesSearchBarWhenScrolling = false
        viewController.definesPresentationContext = true
    }

    fileprivate func search(_ query: String?) {
        reply(to: "connect", with: QueryMessageData(query: query))
    }
}

private extension NativeSearchComponent {
    struct MessageData: Decodable {
        let placeholder: String?
    }

    struct QueryMessageData: Encodable {
        let query: String?
    }
}

private final class Updater: NSObject, UISearchResultsUpdating {
    private weak var component: NativeSearchComponent?

    init(component: NativeSearchComponent) {
        self.component = component
    }

    func updateSearchResults(for searchController: UISearchController) {
        component?.search(searchController.searchBar.text)
    }
}
