import SwiftUI

enum MainTab: CaseIterable {
    case radar, chats, me

    var title: String {
        switch self {
        case .radar: return "주변"
        case .chats: return "채팅"
        case .me: return "마이"
        }
    }

    var symbol: String {
        switch self {
        case .radar: return "dot.radiowaves.left.and.right"
        case .chats: return "bubble.left.and.bubble.right"
        case .me: return "person"
        }
    }

    var activeSymbol: String {
        switch self {
        case .radar: return "dot.radiowaves.left.and.right"
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .me: return "person.fill"
        }
    }
}

/// 로그인 후 메인: 탭 화면 + 하단 앱바. 채팅방에 들어가면 앱바는 가려짐
struct MainView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            // 탭·채팅방 어디에 있든 위치를 보내야 방을 벗어난 걸 서버가 안다
            ZStack {
                switch app.tab {
                case .radar: RadarView().transition(.opacity)
                case .chats: ChatsView().transition(.opacity)
                case .me: SettingsView().transition(.opacity)
                }
            }
            .animation(Motion.settle(0.2), value: app.tab)
            .navigationTitle(app.tab == .radar ? "" : app.tab.title)
            .navigationBarTitleDisplayMode(.inline)
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
        .task { await app.presenceLoop() }
    }
}

struct RippleTabBar: View {
    @Binding var selection: MainTab
    @State private var bounces: [MainTab: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    item(tab)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
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
            bounces[tab, default: 0] += 1
        } label: {
            VStack(spacing: 4) {
                Image(systemName: active ? tab.activeSymbol : tab.symbol)
                    .font(.system(size: 21, weight: active ? .semibold : .regular))
                    .symbolEffect(.bounce.down, value: bounces[tab, default: 0])
                    .frame(height: 26)
                Text(tab.title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? Theme.foreground : Theme.mutedForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
            .animation(Motion.settle(), value: active)
        }
        .buttonStyle(PressStyle(scale: 0.92, dim: 1))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
