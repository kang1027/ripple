import CoreLocation
import Foundation
import UIKit

// MARK: - 위치

/// 앱을 쓰는 중에는 레이더용으로 촘촘히, 백그라운드에서는 근처 사람 알림용으로 듬성듬성 받는다.
/// 백그라운드 위치는 이 서비스가 직접 서버에 보낸다 (background=true)
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    var location: CLLocation?
    var authorization: CLAuthorizationStatus = .notDetermined
    private let manager = CLLocationManager()
    private(set) var isBackground = false
    private var lastBackgroundReport = Date.distantPast
    private let backgroundReportEvery: TimeInterval = 30
    private static let askedAlwaysKey = "ripple.location.askedAlways"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    /// 앱이 내려갈 때. 로그인돼 있으면 위치를 계속 받아 근처 사람 알림에 쓴다
    func enterBackground() {
        isBackground = true
        guard TokenStore.shared.accessToken != nil, isAuthorized else {
            manager.stopUpdatingLocation()
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.pausesLocationUpdatesAutomatically = true
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 30
        manager.startUpdatingLocation()
        // '항상 허용'이면 앱이 종료돼도 크게 움직이면 다시 깨운다
        if manager.authorizationStatus == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        }
        if let location { report(location, background: true) }
    }

    /// 앱이 다시 올라올 때. 서버에 '보고 있음'을 바로 알린다
    func enterForeground() {
        isBackground = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        // 백그라운드에서 iOS가 업데이트를 멈췄으면 스스로 다시 시작하지 않아서 직접 켠다
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        if let location { report(location, background: false) }
    }

    private var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized {
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
        }
        // '앱을 사용하는 동안'을 받은 뒤 한 번만 '항상 허용'을 물어본다 (근처 사람 알림용)
        if authorization == .authorizedWhenInUse, !UserDefaults.standard.bool(forKey: Self.askedAlwaysKey) {
            UserDefaults.standard.set(true, forKey: Self.askedAlwaysKey)
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        location = last
        if isBackground, Date().timeIntervalSince(lastBackgroundReport) >= backgroundReportEvery {
            report(last, background: true)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        if !isBackground { manager.startUpdatingLocation() }
    }

    /// 마지막 위치가 이보다 오래됐으면 지금 위치가 아니다
    static let staleAfter: TimeInterval = 15

    /// 앱 사용 중 호출. 위치가 오래됐으면 업데이트를 다시 켜고, 지금 위치로 믿을 수 있는 값만 돌려준다
    func freshLocation() -> CLLocation? {
        guard let location, location.horizontalAccuracy >= 0 else {
            if isAuthorized { manager.startUpdatingLocation() }
            return nil
        }
        if Date().timeIntervalSince(location.timestamp) > Self.staleAfter {
            if isAuthorized { manager.startUpdatingLocation() }
            return nil
        }
        return location
    }

    private func report(_ loc: CLLocation, background: Bool) {
        guard TokenStore.shared.accessToken != nil, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 100 else { return }
        if background { lastBackgroundReport = Date() }
        struct Body: Encodable { let lat: Double; let lng: Double; let accuracy: Double; let background: Bool }
        let body = Body(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy, background: background)
        Task { @MainActor in
            // 백그라운드에서 요청이 끝날 때까지 앱이 잠들지 않게
            let task = UIApplication.shared.beginBackgroundTask(withName: "presence")
            let _: PresenceOut? = try? await APIClient.shared.request("POST", "/presence", body: body)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}

// MARK: - WebSocket (자동 재연결 + ping)

final class WebSocketClient {
    var onEvent: ((Data) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var url: URL?
    private var running = false
    private var failures = 0
    private var observers: [NSObjectProtocol] = []
    /// 앱이 내려가 일부러 닫은 상태. 이때는 끊김으로 보고 다시 붙지 않는다
    private var suspended = false

    func connect(_ url: URL) {
        self.url = url
        running = true
        failures = 0
        observeAppState()
        open()
    }

    func disconnect() {
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        close()
    }

    /// 앱을 내리면 소켓을 바로 닫아 서버가 '이 화면을 안 보고 있음'을 즉시 알게 한다 (그래야 채팅 알림이 온다).
    /// 다시 올라오면 같은 주소로 다시 붙는다
    private func observeAppState() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.suspended = true
                self?.close()
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.suspended else { return }
                self.suspended = false
                self.failures = 0
                self.open()
            },
        ]
    }

    private func close() {
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func open() {
        guard let url, running, !suspended else { return }
        let next = URLSession.shared.webSocketTask(with: url)
        task = next
        next.resume()
        receive(next)
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.send(["type": "ping"])
            }
        }
    }

    private func receive(_ current: URLSessionWebSocketTask) {
        current.receive { [weak self] result in
            guard let self else { return }
            // 닫고 새로 연 뒤에 옛 소켓에서 오는 결과는 무시
            guard self.task === current else { return }
            switch result {
            case .success(let message):
                self.failures = 0
                switch message {
                case .string(let text): self.onEvent?(Data(text.utf8))
                case .data(let data): self.onEvent?(data)
                @unknown default: break
                }
                self.receive(current)
            case .failure:
                self.failures += 1
                guard self.running, !self.suspended, self.failures < 6 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard self.task === current else { return }
                    self.open()
                }
            }
        }
    }
}
