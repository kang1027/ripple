import SwiftUI

/// 채팅 탭: 지금 들어가 있는 방 + 참여한 토픽
struct ChatsView: View {
    @Environment(AppState.self) private var app
    @State private var chats: ChatsOut?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("지금 있는 방") {
                    if let room = chats?.room {
                        roomRow(room)
                    } else if chats != nil {
                        emptyRoom
                    }
                }
                .riseIn(0.02)

                section("참여한 토픽") {
                    if let topics = chats?.topics, !topics.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(topics.enumerated()), id: \.element.id) { i, topic in
                                if i > 0 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 68) }
                                topicRow(topic)
                            }
                        }
                        .background(Theme.background)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
                    } else if chats != nil {
                        Text("대화에서 같은 이야기가 나오면 토픽 봇이 토픽방을 만들어 줘요")
                            .font(.subheadline)
                            .foregroundStyle(Theme.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.muted))
                    }
                }
                .riseIn(0.08)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.destructive)
                }
            }
            .padding(20)
        }
        .overlay { if chats == nil && error == nil { ProgressView() } }
        .refreshable { await load() }
        .task(id: app.chatsRevision) { await load() }
        .animation(Motion.settle(), value: chats?.room?.id)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mutedForeground)
            content()
        }
    }

    private func roomRow(_ room: RoomOut) -> some View {
        Button {
            Haptics.tap()
            app.path.append(.room(room))
        } label: {
            HStack(spacing: 14) {
                RippleMark(size: 40)
                    .padding(6)
                    .background(Circle().fill(Theme.muted))
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.areaName.isEmpty ? "이 근처 채팅방" : room.areaName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.foreground)
                    HStack(spacing: 6) {
                        ShadAvatarStack(urls: room.avatars, size: 18)
                        Text("\(room.memberCount)명 참여 중")
                            .font(.footnote)
                            .foregroundStyle(Theme.mutedForeground)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
            }
            .padding(14)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.98))
    }

    private var emptyRoom: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("아직 들어간 방이 없어요")
                .font(.system(size: 16, weight: .semibold))
            Text("주변에서 같은 공간에 있는 사람들과 채팅을 시작해 보세요")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground)
            ShadButton(title: "주변 보러 가기", variant: .outline, compact: true) {
                Haptics.select()
                app.tab = .radar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.muted))
    }

    private func topicRow(_ topic: TopicOut) -> some View {
        Button {
            Haptics.tap()
            app.path.append(.topic(topic))
        } label: {
            HStack(spacing: 12) {
                TopicImage(url: topic.imageUrl, category: topic.category)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(topic.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                    Text("\(topic.memberCount)명 · \(topic.lastMessageAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99, dim: 0.6))
    }

    private func load() async {
        do {
            let out: ChatsOut = try await app.api.request("GET", "/me/chats")
            chats = out
            error = nil
        } catch {
            if chats == nil { self.error = error.localizedDescription }
        }
    }
}
