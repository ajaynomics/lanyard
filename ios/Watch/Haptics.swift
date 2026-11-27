import WatchKit

/// The Watch's own taps, as Apple's Human Interface Guidelines use them: one
/// for each outcome the person waits on, none for routine loading.
extension WatchHaptic {
    @MainActor
    func play() {
        WKInterfaceDevice.current().play(type)
    }

    private var type: WKHapticType {
        switch self {
        case .success: .success
        case .failure: .failure
        case .retry: .retry
        case .notification: .notification
        }
    }
}
