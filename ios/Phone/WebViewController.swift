import HotwireNative
import UIKit

/// Every web page's screen (HotwireConfig.defaultViewController). At the root
/// of a sheet it has a close button at the leading edge, Cancel or Done, as
/// the path configuration says (SheetClose), where bridge components' buttons on the right (a form's
/// submit, a menu) can't take its place, as they took Hotwire Native's own
/// Done. Closing is plain dismissal: a form's unsent words go, as Cancel says.
final class WebViewController: HotwireWebViewController {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let navigationController, navigationController.presentingViewController != nil,
              navigationController.viewControllers.first === self else { return }
        let close = SheetClose(properties: Hotwire.config.pathConfiguration.properties(for: currentVisitableURL))
        let item = UIBarButtonItem(title: close.rawValue, image: nil, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        item.style = close == .done ? .done : .plain
        item.accessibilityIdentifier = "sheet-\(close.rawValue.lowercased())"
        navigationItem.leftBarButtonItem = item
    }
}
