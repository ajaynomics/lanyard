import Foundation

/// The button at the leading edge of every sheet, as iOS's own apps have
/// it (WebViewController): a form, whose submit is on the right (Bridge
/// Components' form), is left by Cancel; anything else by Done. Which is
/// which is the path configuration's to say (`close: cancel`, on forms and
/// signing in), not a path matched here.
enum SheetClose: String, Equatable {
    case cancel = "Cancel"
    case done = "Done"

    /// A page's merged path configuration properties (Hotwire Native's PathProperties).
    init(properties: [String: AnyHashable]) {
        self = properties["close"] as? String == "cancel" ? .cancel : .done
    }
}
