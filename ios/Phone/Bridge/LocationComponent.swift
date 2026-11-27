import CoreLocation
import HotwireNative
import UIKit

/// Receives only a request already claimed by this web session. The fix goes
/// straight to Rails with those same cookies, never through bridge messages.
final class LocationComponent: BridgeComponent {
    override nonisolated class var name: String { "phone-location" }

    private struct Call: Decodable {
        let conversation: String
        let invocation: String
    }

    private struct Receipt: Encodable { let received: Bool }

    private var call: Call?
    private var message: Message?
    private var manager: CLLocationManager?
    private var startedAt: Date?
    private var locating = false
    private var askedPermission = false
    private var deadline: Task<Void, Never>?
    private var posting: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private lazy var locationDelegate = LocationManagerDelegate(owner: self)

    override func onReceive(message: Message) {
        guard message.event == "share", self.message == nil, posting == nil,
              let call: Call = message.data(),
              Int64(call.conversation).map({ $0 > 0 }) == true,
              Int64(call.invocation).map({ $0 > 0 }) == true,
              inForeground else { return }

        self.call = call
        self.message = message
        startedAt = Date()
        let manager = CLLocationManager()
        self.manager = manager
        manager.desiredAccuracy = kCLLocationAccuracyBest
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        manager.delegate = locationDelegate
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { self?.finish("unavailable") }
        }
        checkPermission(manager)
    }

    override func onViewWillDisappear() { stop() }

    fileprivate func authorizationChanged(_ manager: CLLocationManager) {
        checkPermission(manager)
    }

    fileprivate func located(_ manager: CLLocationManager, locations: [CLLocation]) {
        guard manager === self.manager else { return }
        guard let startedAt, inForeground else { stop(); return }
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(fix.coordinate),
              fix.timestamp >= startedAt.addingTimeInterval(-5) else { finish("unavailable"); return }
        finish("shared", fix: .init(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                   accuracy_m: fix.horizontalAccuracy, timestamp: fix.timestamp))
    }

    fileprivate func locationFailed(_ manager: CLLocationManager, error: Error) {
        guard manager === self.manager else { return }
        if (error as? CLError)?.code == .denied {
            checkPermission(manager, requestFailed: true)
        } else {
            finish("unavailable")
        }
    }

    private var inForeground: Bool {
        guard let controller = delegate?.destination as? UIViewController, controller.viewIfLoaded?.window != nil else { return false }
        return UIApplication.shared.applicationState != .background
    }

    private func checkPermission(_ manager: CLLocationManager, requestFailed: Bool = false) {
        Task { [weak self, weak manager] in
            // This check can block; keep it off the main thread even when iOS reports a denial.
            let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
            guard let self, let manager, manager === self.manager else { return }
            guard self.inForeground else { self.stop(); return }
            guard enabled else { self.finish("services_off"); return }
            self.applyPermission(manager, requestFailed: requestFailed)
        }
    }

    private func applyPermission(_ manager: CLLocationManager, requestFailed: Bool) {
        switch manager.authorizationStatus {
        case .restricted:
            finish("restricted")
        case .denied:
            finish("denied")
        case _ where requestFailed:
            finish("unavailable")
        case .notDetermined:
            guard !askedPermission else { return }
            askedPermission = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard !locating else { return }
            locating = true
            manager.requestLocation()
        @unknown default:
            finish("unavailable")
        }
    }

    private func finish(_ outcome: String, fix: PhoneRequests.LocationFix? = nil) {
        guard let message, let call else { return }
        stop()
        guard inForeground, let request = PhoneRequests.locationResult(base: baseURL, conversation: call.conversation,
                                                                      invocation: call.invocation, outcome: outcome, fix: fix) else { return }
        posting = Task { [weak self] in
            let answer = try? await WebSession(base: baseURL).send(request)
            if !Task.isCancelled {
                self?.reply(with: message.replacing(data: Receipt(received: answer?.status == 204)), completion: nil)
            }
            self?.posting = nil
        }
    }

    private func stop() {
        deadline?.cancel()
        deadline = nil
        posting?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
        message = nil
        call = nil
        startedAt = nil
        askedPermission = false
        locating = false
    }
}

// CoreLocation calls the delegate on its manager's creation run loop.
// The bridge creates the manager on the main actor.
@MainActor
private final class LocationManagerDelegate: NSObject, @preconcurrency CLLocationManagerDelegate {
    weak var owner: LocationComponent?

    init(owner: LocationComponent) { self.owner = owner }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        owner?.authorizationChanged(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        owner?.located(manager, locations: locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        owner?.locationFailed(manager, error: error)
    }
}
