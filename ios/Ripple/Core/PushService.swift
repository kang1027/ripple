import UIKit
import UserNotifications

/// 알림을 눌렀을 때 갈 곳
enum PushRoute: Sendable, Equatable {
    case nearby
    case room(id: String)
    case topic(id: String, roomId: String)

    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo["type"] as? String {
        case "nearby":
            self = .nearby
        case "room":
            guard let id = userInfo["room_id"] as? String else { return nil }
            self = .room(id: id)
        case "topic":
            guard let id = userInfo["topic_id"] as? String, let roomId = userInfo["room_id"] as? String else { return nil }
            self = .topic(id: id, roomId: roomId)
        default:
            return nil
        }
    }
}

/// APNs 등록, 기기 토큰 업로드, 알림 표시·탭 처리
@MainActor
final class PushService: NSObject {
    static let shared = PushService()

    /// 알림을 누르면 호출. AppState가 연결한다
    var onOpen: ((PushRoute) -> Void)? {
        didSet {
            if let onOpen, let route = pendingRoute {
                pendingRoute = nil
                onOpen(route)
            }
        }
    }
    private var pendingRoute: PushRoute?
    private(set) var deviceToken: String?

    /// Xcode에서 바로 깐 Debug 빌드는 sandbox, TestFlight·App Store는 production.
    /// 틀려도 서버가 반대 환경으로 한 번 더 보내고 저장값을 고친다
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 로그인·온보딩이 끝난 뒤 호출. 처음이면 권한을 묻고, 허용돼 있으면 토큰을 받는다
    func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func open(_ route: PushRoute) {
        if let onOpen { onOpen(route) } else { pendingRoute = route }
    }

    func didRegister(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await upload() }
    }

    func upload() async {
        guard let deviceToken, TokenStore.shared.accessToken != nil else { return }
        struct Body: Encodable { let token: String; let env: String }
        let _: OkResponse? = try? await APIClient.shared.request(
            "POST", "/push/devices", body: Body(token: deviceToken, env: Self.environment)
        )
    }

    /// 로그아웃 직전, 토큰을 지우기 전에 호출 (다른 계정 알림이 이 기기로 오지 않게)
    func unregister(accessToken: String?) {
        guard let deviceToken, let accessToken else { return }
        var req = URLRequest(url: AppConfig.apiBaseURL.appendingPathComponent("/push/devices/\(deviceToken)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req).resume()
    }
}

extension PushService: UNUserNotificationCenterDelegate {
    /// 앱을 쓰는 중에도 배너로 보여 준다. 지금 보고 있는 방 알림은 서버가 애초에 안 보낸다
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = PushRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PushService.shared.open(route) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushService.shared.configure()
        // 위치 변화로 백그라운드에서 깨어난 경우에도 위치 매니저를 바로 살린다
        if launchOptions?[.location] != nil {
            LocationService.shared.enterBackground()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushService.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}
