import HotwireNative
import UIKit

/// A flash as a toast at the foot of the page (layouts/_flash, web side
/// Bridge Components' toast controller, whose messages this speaks).
///
/// The app's own, in place of Bridge Components' toast, for three things
/// that one lacks: VoiceOver reads it, it follows dark mode and the text
/// size, and it holds still while shown. The library's holds inside an
/// animation's delay, and a UI test waits for animations to end before it
/// looks, by which time the toast is gone (seen on the M4).
final class NoticeComponent: BridgeComponent {
    override nonisolated class var name: String { "toast" }

    static let shownFor: Duration = .seconds(4)

    private var viewController: UIViewController? { delegate?.destination as? UIViewController }

    override func onReceive(message: Message) {
        guard message.event == "show", let notice: Notice = message.data(), let view = viewController?.view else { return }
        show(notice.message, in: view)
    }

    private func show(_ text: String, in view: UIView) {
        let label = NoticeLabel(text: text)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
        UIView.animate(withDuration: 0.25) { label.alpha = 1 }
        Task { @MainActor [weak label] in
            try? await Task.sleep(for: Self.shownFor)
            UIView.animate(withDuration: 0.25, animations: { label?.alpha = 0 }) { _ in label?.removeFromSuperview() }
        }
    }

    private struct Notice: Decodable {
        let message: String
    }
}

private final class NoticeLabel: UILabel {
    private let inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    init(text: String) {
        super.init(frame: .zero)
        self.text = text
        translatesAutoresizingMaskIntoConstraints = false
        numberOfLines = 0
        textAlignment = .center
        font = .preferredFont(forTextStyle: .subheadline)
        adjustsFontForContentSizeCategory = true
        textColor = .label
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        alpha = 0
        isAccessibilityElement = true
        accessibilityIdentifier = "toast"
        accessibilityLabel = text
    }

    required init?(coder: NSCoder) { nil }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + inset.left + inset.right, height: size.height + inset.top + inset.bottom)
    }
}
