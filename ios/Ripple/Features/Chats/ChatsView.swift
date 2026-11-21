import SwiftUI

/// 내가 참여한 방 탭: 장소를 떠나도 이어지는 토픽방 목록.
/// 왼쪽으로 밀면 나가기, 오른쪽으로 밀면 알림 끄기 (한 번에 한 줄만 열림)
struct ChatsView: View {
    @Environment(AppState.self) private var app
    @State private var chats: ChatsOut?
    @State private var error: String?
    @State private var place = ChatsView.allPlaces
    @State private var manage: TopicOut?
    @State private var leaving: TopicOut?

    static let allPlaces = "전체 장소"

    private var topics: [TopicOut] { chats?.topics ?? [] }
    private var places: [String] {
        var seen: [String] = []
        for t in topics { if let p = t.placeName, !p.isEmpty, !seen.contains(p) { seen.append(p) } }
        return seen
    }
    private var visible: [TopicOut] {
        place == Self.allPlaces ? topics : topics.filter { $0.placeName == place }
    }

    var body: some View {
        List {
            Group {
                PageTitle(title: "내가 참여한 방")
                HStack(spacing: 12) {
                    Text("장소는 달라도, 이야기는 계속")
                        .appFont(12)
                        .foregroundStyle(Theme.mutedForeground)
                    Spacer()
                    if !places.isEmpty { placePicker }
                }
                .padding(.top, 16)
                .padding(.bottom, 4)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            ForEach(visible) { topic in
                Button {
                    Haptics.tap()
                    WaveTransition.shared.push { app.path.append(.topic(topic)) }
                } label: {
                    TopicRoomRow(topic: topic, place: nil)
                        .overlay(alignment: .trailing) {
                            Button { manage = topic } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.mutedForeground)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 8)
                            .accessibilityLabel("\(TopicTitle.hashtag(topic.title)) 방 관리")
                        }
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { leaving = topic } label: { Label("나가기", systemImage: "rectangle.portrait.and.arrow.right") }
                        .tint(Theme.destructive)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { Task { await toggleMute(topic) } } label: {
                        Label(topic.muted == true ? "알림 켜기" : "알림 끄기", systemImage: topic.muted == true ? "bell" : "bell.slash")
                    }
                    .tint(Theme.primary)
                }
            }

            if chats != nil && visible.isEmpty {
                EmptyState(
                    title: "아직 남겨둔 이야기가 없어요",
                    message: "가까운 방에서 첫 이야기를 시작해 볼까요?",
                    action: ("주변 방 보기", { app.tab = .nearby })
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if let error {
                Text(error).appFont(12).foregroundStyle(Theme.destructive)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { if chats == nil && error == nil { ProgressView() } }
        .refreshable { await load() }
        // 방에서 빠지거나 자동 재입장할 때 AppState가 chatsRevision을 올린다
        .task(id: app.chatsRevision) { await load() }
        .animation(Motion.settle(), value: visible.map(\.id))
        .sheet(item: $manage) { topic in manageSheet(topic) }
        .sheet(item: $leaving) { topic in leaveSheet(topic) }
    }

    private var placePicker: some View {
        Menu {
            Picker("참여한 장소", selection: $place) {
                Text(Self.allPlaces).tag(Self.allPlaces)
                ForEach(places, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(place).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .appFont(12, .semibold)
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 160)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xl).fill(Theme.secondary))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl).stroke(Theme.border, lineWidth: 1))
        }
        .accessibilityLabel("참여한 장소")
    }

    private func manageSheet(_ topic: TopicOut) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(TopicTitle.hashtag(topic.title)).appFont(18, .bold).foregroundStyle(Theme.foreground)
            if let p = topic.placeName {
                Text(p).appFont(12).foregroundStyle(Theme.mutedForeground).padding(.top, 4)
            }
            sheetRow(topic.muted == true ? "알림 켜기" : "알림 끄기", topic.muted == true ? "bell" : "bell.slash", Theme.foreground) {
                manage = nil
                Task { await toggleMute(topic) }
            }
            .padding(.top, 16)
            sheetRow("방 나가기", "rectangle.portrait.and.arrow.right", Theme.destructive) {
                manage = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    leaving = topic
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .rippleSheet(detents: [.height(230)])
    }

    private func leaveSheet(_ topic: TopicOut) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(TopicTitle.hashtag(topic.title)) 방에서 나갈까요?").appFont(18, .bold).foregroundStyle(Theme.foreground)
            Text("참여한 방 목록에서 사라져요.").appFont(14).foregroundStyle(Theme.mutedForeground).padding(.top, 8)
            HStack(spacing: 8) {
                ShadButton(title: "취소", variant: .secondary) { leaving = nil }
                ShadButton(title: "나가기", variant: .destructive, systemImage: "rectangle.portrait.and.arrow.right") {
                    leaving = nil
                    Task { await leave(topic) }
                }
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .rippleSheet(detents: [.height(220)])
    }

    private func sheetRow(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 22)
                Text(title).appFont(14, .semibold)
                Spacer()
            }
            .foregroundStyle(color)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98, dim: 0.6))
    }

    private func toggleMute(_ topic: TopicOut) async {
        Haptics.select()
        let next = !(topic.muted ?? false)
        do {
            let updated: TopicOut = try await app.api.request("PATCH", "/topics/\(topic.id)", body: ["muted": next])
            replace(updated)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func leave(_ topic: TopicOut) async {
        do {
            let _: OkResponse = try await app.api.request("POST", "/topics/\(topic.id)/leave")
            Haptics.success()
            withAnimation(Motion.settle()) {
                if let c = chats { chats = ChatsOut(room: c.room, topics: c.topics.filter { $0.id != topic.id }) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replace(_ topic: TopicOut) {
        guard let c = chats else { return }
        chats = ChatsOut(room: c.room, topics: c.topics.map { $0.id == topic.id ? topic : $0 })
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
