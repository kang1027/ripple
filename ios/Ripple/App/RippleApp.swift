import KakaoSDKAuth
import KakaoSDKCommon
import SwiftUI

@main
struct RippleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppState()
    @State private var location = LocationService.shared

    init() {
        KakaoSDK.initSDK(appKey: AppConfig.kakaoAppKey)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(location)
                .preferredColorScheme(.light)
                .tint(Theme.primary)
                .onOpenURL { url in
                    if AuthApi.isKakaoTalkLoginUrl(url) {
                        _ = AuthController.handleOpenUrl(url: url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: location.enterBackground()
            case .active: location.enterForeground()
            default: break
            }
        }
    }
}

enum Route: Hashable {
    case room(RoomOut)
    case topic(TopicOut)
    case settings
}

@MainActor
@Observable
final class AppState {
    enum Phase { case loading, signedOut, phone, profile, ready }

    var phase: Phase = .loading
    var me: UserOut?
    var path: [Route] = []
    var tab: MainTab = .radar
    /// 방에서 빠지거나 다시 들어갈 때마다 올라감. 채팅 탭이 이걸 보고 목록을 다시 불러온다
    var chatsRevision = 0
    /// 화면 전환 방향. 뒤로 갈 때는 왼쪽에서 들어옴
    var forward = true

    let api = APIClient.shared

    /// 로그인 전에 알림을 눌렀으면 준비된 뒤에 연다
    private var pendingRoute: PushRoute?

    init() {
        api.onUnauthorized = { [weak self] in self?.signOut() }
        PushService.shared.onOpen = { [weak self] route in
            Task { await self?.open(route) }
        }
    }

    func open(_ route: PushRoute) async {
        guard phase == .ready else {
            pendingRoute = route
            return
        }
        forward = true
        switch route {
        case .nearby:
            tab = .radar
            path = []
        case .room(let id):
            guard let room: RoomOut = try? await api.request("GET", "/rooms/\(id)") else { return }
            path = [.room(room)]
        case .topic(let id, let roomId):
            guard let room: RoomOut = try? await api.request("GET", "/rooms/\(roomId)") else { return }
            if let topic: TopicOut = try? await api.request("GET", "/topics/\(id)"), topic.isMember {
                path = [.room(room), .topic(topic)]
            } else {
                path = [.room(room)]
            }
        }
    }

    /// 앱을 쓰는 동안 2초마다 위치를 보낸다. 방을 벗어나 빠지면 그 방 화면을 닫고 레이더로 돌아간다
    func presenceLoop() async {
        let location = LocationService.shared
        location.start()
        while !Task.isCancelled {
            // 오래된 위치를 보내면 멀어졌던 자리에 계속 있는 걸로 보여서 다시 붙어도 못 찾는다
            if !location.isBackground, let loc = location.freshLocation() {
                struct Body: Encodable { let lat: Double; let lng: Double; let accuracy: Double; let onRadar: Bool }
                // 레이더를 보고 있지 않으면 서버가 근처에 새 사람이 올 때 알림을 보낸다
                let onRadar = tab == .radar && path.isEmpty
                let body = Body(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy, onRadar: onRadar)
                if let out: PresenceOut = try? await api.request("POST", "/presence", body: body) {
                    let left = out.leftRooms ?? []
                    let joined = out.joinedRooms ?? []
                    if !left.isEmpty { leaveRooms(Set(left)) }
                    if !left.isEmpty || !joined.isEmpty { chatsRevision += 1 }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// 동네방에서 빠지면 그 방 화면만 닫는다. 토픽방은 장소를 떠나도 유지되므로 열려 있으면 그대로 둔다
    private func leaveRooms(_ ids: Set<String>) {
        let kept = path.filter { route in
            if case .room(let r) = route { return !ids.contains(r.id) }
            return true
        }
        guard kept.count != path.count else { return }
        forward = false
        path = kept
        if path.isEmpty { tab = .radar }
    }

    func bootstrap() async {
        guard TokenStore.shared.accessToken != nil else {
            phase = .signedOut
            return
        }
        await refreshMe()
    }

    func applyLogin(_ token: TokenOut) async {
        TokenStore.shared.save(access: token.accessToken, refresh: token.refreshToken)
        await refreshMe()
    }

    func refreshMe() async {
        forward = true
        do {
            let user: UserOut = try await api.request("GET", "/me")
            me = user
            switch user.status {
            case "pending_phone": phase = .phone
            case "pending_profile": phase = .profile
            default:
                phase = .ready
                await PushService.shared.requestAndRegister()
                if let route = pendingRoute {
                    pendingRoute = nil
                    await open(route)
                }
            }
        } catch {
            if phase == .loading { phase = .signedOut }
        }
    }

    /// 온보딩에서 뒤로가기: 키보드부터 내리고 내려간 뒤에 로그인 화면으로
    func leaveOnboarding() async {
        Keyboard.dismiss()
        try? await Task.sleep(for: .milliseconds(260))
        signOut()
    }

    func signOut() {
        forward = false
        tab = .radar
        PushService.shared.unregister(accessToken: TokenStore.shared.accessToken)
        TokenStore.shared.clear()
        me = nil
        path = []
        phase = .signedOut
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            switch app.phase {
            case .loading:
                RippleMark(size: 64).transition(.opacity)
            case .signedOut:
                LoginView().transition(pageTransition)
            case .phone:
                PhoneVerifyView().transition(pageTransition)
            case .profile:
                ProfileSetupView().transition(pageTransition)
            case .ready:
                MainView().transition(pageTransition)
            }
        }
        .animation(Motion.page, value: app.phase)
        .task { await app.bootstrap() }
    }

    /// 온보딩 단계가 넘어갈 때 오른쪽에서 밀려 들어옴
    private var pageTransition: AnyTransition {
        let dx: CGFloat = app.forward ? 40 : -40
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: dx)),
            removal: .opacity.combined(with: .offset(x: -dx))
        )
    }
}
