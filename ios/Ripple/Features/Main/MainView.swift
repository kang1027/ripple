import SwiftUI

/// 하단 탭 (디자인: 홈 · 주변 방 · 내가 참여한 방 · 내 정보).
/// 케이스 이름은 AppState(RippleApp.swift)가 쓰므로 바꾸지 않는다. `.radar`가 홈(수영장)이다.
enum MainTab: CaseIterable {
    case radar, nearby, chats, me

    var title: String {
        switch self {
        case .radar: return "홈"
        case .nearby: return "주변 방"
        case .chats: return "내가 참여한 방"
        case .me: return "내 정보"
        }
    }

    var symbol: String {
        switch self {
        case .radar: return "house"
        case .nearby: return "mappin.and.ellipse"
        case .chats: return "person.2"
        case .me: return "person"
        }
    }
}

/// 로그인 후 메인: 탭 화면 + 하단 탭바. 채팅방에 들어가면 탭바는 가려짐
struct MainView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            ZStack {
                switch app.tab {
                case .radar: RadarView().transition(.opacity)
                case .nearby: NearbyRoomsView().transition(.opacity)
                case .chats: ChatsView().transition(.opacity)
                case .me: SettingsView().transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .animation(Motion.settle(0.2), value: app.tab)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RippleTabBar(selection: $app.tab)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .room(let room): ChatView(kind: .room(room))
                case .topic(let topic): ChatView(kind: .topic(topic))
                case .settings: SettingsView()
                }
            }
        }
        // 탭·채팅방 어디에 있든 위치를 보내야 방을 벗어난 걸 서버가 안다
        .task { await app.presenceLoop() }
        .preferredColorScheme(.light)
    }
}

struct RippleTabBar: View {
    @Binding var selection: MainTab
    @Namespace private var dot

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    item(tab)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        .background(Theme.background.ignoresSafeArea(edges: .bottom))
    }

    private func item(_ tab: MainTab) -> some View {
        let active = selection == tab
        return Button {
            if selection != tab {
                Haptics.select()
                selection = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 20)
                Text(tab.title)
                    .appFont(11, .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? Theme.primary : Theme.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .overlay(alignment: .top) {
                if active {
                    Circle()
                        .fill(Theme.primary)
                        .frame(width: 4, height: 4)
                        .offset(y: -8)
                        .matchedGeometryEffect(id: "tabdot", in: dot)
                }
            }
            .contentShape(Rectangle())
            .animation(Motion.settle(), value: active)
        }
        .buttonStyle(PressStyle(scale: 0.94, dim: 1))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
