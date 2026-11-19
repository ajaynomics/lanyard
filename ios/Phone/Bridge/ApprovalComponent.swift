import HotwireNative
import UIKit

/// A waiting card opened alone (approvals/show, a sheet): Allow and Deny in
/// the sheet's own toolbar, at the foot, where a thumb is. A tap replies with
/// the choice, and the page presses its own button, so the answer goes as the
/// web's does; the page's form gives the haptic (Bridge Components' haptic).
/// No library component draws a pair of choices like this, so it is the app's
/// (web side: app/javascript/native/approval_controller.js).
final class ApprovalComponent: BridgeComponent {
    override nonisolated class var name: String { "approval" }

    private var viewController: UIViewController? { delegate?.destination as? UIViewController }

    override func onReceive(message: Message) {
        switch message.event {
        case "connect":
            guard let choices: Choices = message.data() else { return }
            show(choices)
        case "disconnect":
            hide()
        case "failed":
            // The answer never arrived (offline, a server error): the page says why, and the choice is offered again.
            viewController?.toolbarItems?.forEach { $0.isEnabled = true }
        default:
            break
        }
    }

    override func onViewWillDisappear() {
        hide()
    }

    private func show(_ choices: Choices) {
        guard let viewController else { return }
        var items: [UIBarButtonItem] = []
        if let deny = choices.deny {
            let button = UIBarButtonItem(title: deny, image: nil, primaryAction: UIAction { [weak self] _ in self?.choose("deny") })
            button.tintColor = .systemRed
            button.accessibilityIdentifier = "approval-deny"
            items.append(button)
        }
        items.append(.flexibleSpace())
        if let allow = choices.allow {
            let button = UIBarButtonItem(title: allow, image: nil, primaryAction: UIAction { [weak self] _ in self?.choose("allow") })
            button.style = .done
            button.accessibilityIdentifier = "approval-allow"
            items.append(button)
        }
        viewController.toolbarItems = items
        viewController.navigationController?.setToolbarHidden(false, animated: true)
    }

    private func hide() {
        viewController?.navigationController?.setToolbarHidden(true, animated: true)
        viewController?.toolbarItems = nil
    }

    private func choose(_ choice: String) {
        // One answer: the buttons go until the next page says otherwise.
        viewController?.toolbarItems?.forEach { $0.isEnabled = false }
        reply(to: "connect", with: Choice(choice: choice))
    }

    private struct Choices: Decodable {
        let allow: String?
        let deny: String?
    }

    private struct Choice: Encodable {
        let choice: String
    }
}
