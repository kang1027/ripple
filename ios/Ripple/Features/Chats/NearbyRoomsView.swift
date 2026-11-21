import SwiftUI

/// 주변 방 탭: 지금 들어가 있는 동네 리플에서 생긴 토픽방들.
/// 방에 들어가기 전 주변 토픽방을 보여주는 API가 생기면 그걸로 바꾼다.
struct NearbyRoomsView: View {
    @Environment(AppState.self) private var app
    @State private var room: RoomOut?
    @State private var topics: [TopicOut] = []
    @State private var loaded = false
    @State private var opening: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "주변 방")
                HStack(spacing: 4) {
                    Image(systemName: "mappin").font(.system(size: 11, weight: .semibold))
                    Text(room.map { "지금 \($0.areaName)" } ?? "리플에 들어가면 주변 토픽방이 보여요")
                }
                .appFont(12, .semibold)
                .foregroundStyle(Theme.mutedForeground)
                .padding(.top, 16)

                VStack(spacing: 8) {
                    ForEach(topics) { topic in
                        Button { Task { await open(topic) } } label: {
                            TopicRoomRow(topic: topic, place: room?.areaName)
                                .opacity(opening == topic.id ? 0.6 : 1)
                        }
                        .buttonStyle(PressStyle(scale: 0.98))
                    }
                }
                .padding(.top, 12)

                if loaded && topics.isEmpty {
                    if room == nil {
                        EmptyState(
                            title: "아직 들어간 리플이 없어요",
                            message: "홈에서 리플에 참여하면 이곳에서 생긴 토픽방이 모여요",
                            action: ("홈으로 가기", { app.tab = .radar })
                        )
                    } else {
                        EmptyState(
                            title: "아직 토픽방이 없어요",
                            message: "대화에서 같은 이야기가 이어지면 Ripple 봇이 토픽방을 열어 줘요"
                        )
                    }
                }
                if let error {
                    Text(error).appFont(12).foregroundStyle(Theme.destructive).padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .refreshable { await load() }
        .task(id: app.chatsRevision) { await load() }
    }

    private func load() async {
        do {
            let chats: ChatsOut = try await app.api.request("GET", "/me/chats")
            room = chats.room
            if let room = chats.room {
                topics = try await app.api.request("GET", "/rooms/\(room.id)/topics")
            } else {
                topics = []
            }
            error = nil
        } catch {
            if !loaded { self.error = error.localizedDescription }
        }
        loaded = true
    }

    private func open(_ topic: TopicOut) async {
        Haptics.tap()
        if topic.isMember {
            app.path.append(.topic(topic))
            return
        }
        opening = topic.id
        defer { opening = nil }
        do {
            let joined: TopicOut = try await app.api.request("POST", "/topics/\(topic.id)/join")
            app.path.append(.topic(joined))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
