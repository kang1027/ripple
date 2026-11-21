import SwiftUI

enum ChatKind: Hashable {
    case room(RoomOut)
    case topic(TopicOut)
}

/// 보냈지만 서버가 아직 돌려주지 않은 내 메시지
struct PendingMessage: Hashable {
    let clientId: String
    let body: String
    var failed = false
}

/// 화면에 그리는 한 줄. 내 메시지는 client_id를 키로 써서 '보내는 중 → 보냄'이 같은 말풍선에서 이어짐
struct ChatItem: Identifiable {
    let id: String
    let message: MessageOut?
    let pending: PendingMessage?
}

@MainActor
@Observable
final class ChatViewModel {
    let kind: ChatKind
    var room: RoomOut?
    var messages: [MessageOut] = []
    var pending: [PendingMessage] = []
    var topics: [TopicOut] = []
    var draft = ""
    var readOnly = false
    var error: String?

    private let api = APIClient.shared
    private let ws = WebSocketClient()

    init(kind: ChatKind) {
        self.kind = kind
        if case .room(let r) = kind { room = r }
    }

    var roomId: String {
        switch kind {
        case .room(let r): return r.id
        case .topic(let t): return t.roomId
        }
    }

    var items: [ChatItem] {
        messages.map { ChatItem(id: $0.clientId ?? "m\($0.id)", message: $0, pending: nil) }
            + pending.map { ChatItem(id: $0.clientId, message: nil, pending: $0) }
    }

    var title: String {
        if case .topic(let t) = kind { return t.title }
        return room?.areaName ?? ""
    }

    func load() async {
        do {
            room = try await api.request("GET", "/rooms/\(roomId)")
            readOnly = room?.readOnly ?? false
            switch kind {
            case .room(let r):
                messages = try await api.request("GET", "/rooms/\(r.id)/messages")
                topics = try await api.request("GET", "/rooms/\(r.id)/topics")
            case .topic(let t):
                messages = try await api.request("GET", "/topics/\(t.id)/messages")
            }
        } catch {
            self.error = error.localizedDescription
        }
        connect()
    }

    func connect() {
        guard let token = TokenStore.shared.accessToken else { return }
        let path: String
        switch kind {
        case .room(let r): path = "/ws/rooms/\(r.id)"
        case .topic(let t): path = "/ws/topics/\(t.id)"
        }
        guard let url = AppConfig.webSocketURL(path: path, token: token) else { return }
        ws.onEvent = { [weak self] data in
            Task { @MainActor in self?.handle(data) }
        }
        ws.connect(url)
    }

    func disconnect() { ws.disconnect() }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let cid = UUID().uuidString
        draft = ""
        withAnimation(Motion.bubble) { pending.append(PendingMessage(clientId: cid, body: text)) }
        transmit(cid, text)
    }

    func retry(_ item: PendingMessage) {
        guard let i = pending.firstIndex(where: { $0.clientId == item.clientId }) else { return }
        withAnimation(Motion.settle()) { pending[i].failed = false }
        transmit(item.clientId, item.body)
    }

    /// 보내고 8초 안에 서버가 돌려주지 않으면 실패로 표시
    private func transmit(_ cid: String, _ text: String) {
        ws.send(["type": "send", "body": text, "client_id": cid])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, let i = self.pending.firstIndex(where: { $0.clientId == cid }) else { return }
            withAnimation(Motion.settle()) { self.pending[i].failed = true }
        }
    }

    private func failAllPending() {
        withAnimation(Motion.settle()) {
            for i in pending.indices { pending[i].failed = true }
        }
    }

    private func handle(_ data: Data) {
        guard let event = try? api.decoder.decode(WSEvent.self, from: data) else { return }
        switch event.type {
        case "message":
            if let m = event.message, !messages.contains(where: { $0.id == m.id }) {
                withAnimation(Motion.bubble) {
                    if let cid = m.clientId { pending.removeAll { $0.clientId == cid } }
                    messages.append(m)
                }
                if m.type == MessageType.topicCard { Haptics.success() }
            }
        case "members":
            room?.memberCount = event.memberCount ?? room?.memberCount ?? 0
            if let a = event.avatars { room?.avatars = a }
        case "topic_created":
            if let t = event.topic, !topics.contains(where: { $0.id == t.id }) {
                topics.insert(t, at: 0)
                Task { await reloadTopics() }
            }
        case "out_of_range":
            if event.userId == TokenStoreUser.id { readOnly = true }
        case "error":
            if event.code == "read_only" { readOnly = true }
            failAllPending()
        default:
            break
        }
    }

    func reloadTopics() async {
        topics = (try? await api.request("GET", "/rooms/\(roomId)/topics")) ?? topics
    }

    func isMember(_ topicId: String) -> Bool {
        topics.first { $0.id == topicId }?.isMember ?? false
    }

    func joinTopic(_ topicId: String) async -> TopicOut? {
        do {
            let topic: TopicOut = try await api.request("POST", "/topics/\(topicId)/join")
            if let i = topics.firstIndex(where: { $0.id == topic.id }) { topics[i] = topic } else { topics.insert(topic, at: 0) }
            return topic
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func report(_ message: MessageOut) async {
        struct Body: Encodable { let messageId: Int; let reason: String }
        let _: OkResponse? = try? await api.request("POST", "/reports", body: Body(messageId: message.id, reason: "user_report"))
    }

    func block(_ userId: String) async {
        let _: OkResponse? = try? await api.request("POST", "/blocks", body: ["user_id": userId])
        withAnimation(Motion.settle()) { messages.removeAll { $0.sender?.id == userId } }
    }

    func leave() async {
        let _: OkResponse? = try? await api.request("POST", "/rooms/\(roomId)/leave")
    }
}

/// 현재 로그인 사용자 id (out_of_range 이벤트 판단용)
enum TokenStoreUser {
    @MainActor static var id: String?
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var vm: ChatViewModel
    @State private var showTopics = false

    init(kind: ChatKind) {
        _vm = State(initialValue: ChatViewModel(kind: kind))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.items) { item in
                        itemRow(item).id(item.id)
                    }
                }
                .padding(16)
            }
            // 키보드가 올라와도 마지막 메시지가 아래에 붙어 있게
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.items.count) {
                if let last = vm.items.last { withAnimation(Motion.bubble) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.border).frame(height: 1)
                inputBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showTopics) { topicSheet }
        .task {
            TokenStoreUser.id = app.me?.id
            await vm.load()
        }
        .onDisappear {
            Keyboard.dismiss()
            vm.disconnect()
        }
    }

    // MARK: 헤더

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if case .room = vm.kind {
            ToolbarItem(placement: .topBarLeading) {
                Button { Task { await vm.reloadTopics() }; showTopics = true } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                if case .topic = vm.kind {
                    Text(vm.title).font(.subheadline.bold())
                } else {
                    ShadAvatarStack(urls: vm.room?.avatars ?? [], size: 20)
                }
                Text("\(vm.room?.memberCount ?? 0)명 · \(vm.room?.areaName ?? "")")
                    .font(.caption2).foregroundStyle(Theme.mutedForeground)
            }
        }
        if case .room = vm.kind {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("방 나가기", role: .destructive) {
                        Task {
                            await vm.leave()
                            app.path.removeAll()
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }

    // MARK: 메시지

    /// 보내는 중(pending)과 보낸 내 메시지는 같은 분기로 그려야 확인될 때 말풍선이 다시 튀지 않음
    @ViewBuilder
    private func itemRow(_ item: ChatItem) -> some View {
        if let own = ownContent(item) {
            ownBubble(own.text, sending: own.sending, failed: own.failed) {
                if let p = item.pending { vm.retry(p) }
            }
            .transition(.bubbleIn(from: .bottomTrailing))
        } else if let m = item.message {
            row(m)
        }
    }

    private func ownContent(_ item: ChatItem) -> (text: String, sending: Bool, failed: Bool)? {
        if let p = item.pending { return (p.body, !p.failed, p.failed) }
        guard let m = item.message, m.type != MessageType.topicCard, m.type != MessageType.system,
              m.sender != nil, m.sender?.id == app.me?.id else { return nil }
        return (m.body, false, false)
    }

    /// 내 말풍선. 보내는 중엔 흐리게, 실패하면 다시 보내기 표시
    private func ownBubble(_ text: String, sending: Bool = false, failed: Bool = false, retry: (() -> Void)? = nil) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 60)
            if failed {
                Button {
                    Haptics.tap()
                    retry?()
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.destructive)
                }
                .buttonStyle(PressStyle(scale: 0.85))
                .accessibilityLabel("다시 보내기")
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            Text(text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(Theme.primaryForeground)
                .background(Theme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .opacity(sending ? 0.55 : 1)
        }
        .animation(Motion.settle(), value: sending)
        .animation(Motion.pop, value: failed)
    }

    @ViewBuilder
    private func row(_ m: MessageOut) -> some View {
        if m.type == MessageType.topicCard, let meta = m.meta {
            topicCard(meta)
                .transition(.bubbleIn(from: .bottom, scale: 0.9))
        } else if m.type == MessageType.system || m.sender == nil {
            Text(m.body).font(.caption).foregroundStyle(Theme.mutedForeground).frame(maxWidth: .infinity)
                .transition(.opacity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                ShadAvatar(url: m.sender?.avatarUrl, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.sender?.nickname ?? "알 수 없음").font(.caption).foregroundStyle(Theme.mutedForeground)
                    Text(m.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.muted)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Spacer(minLength: 40)
            }
            .transition(.bubbleIn(from: .bottomLeading))
            .contextMenu {
                Button("신고하기") { Task { await vm.report(m) } }
                if let uid = m.sender?.id {
                    Button("차단하기", role: .destructive) { Task { await vm.block(uid) } }
                }
            }
        }
    }

    private func topicCard(_ meta: TopicMeta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meta.reminder == true ? "토픽 봇 · 진행 중인 토픽" : "토픽 봇 · 새 토픽")
                .font(.caption).foregroundStyle(Theme.mutedForeground)
            ShadCard {
                TopicImage(url: meta.imageUrl, category: meta.category, iconFont: .title2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(meta.title).font(.headline)
                Text(meta.summary).font(.subheadline).foregroundStyle(Theme.mutedForeground)
                let count = vm.topics.first { $0.id == meta.topicId }?.memberCount ?? meta.memberCount
                Text("\(count)명 참여 중").font(.caption).foregroundStyle(Theme.mutedForeground)
                // 주제를 꺼낸 사람·반응한 사람은 자동 참여. 나머지는 '참여하기'를 눌러야 내 토픽에 들어간다
                ShadButton(title: vm.isMember(meta.topicId) ? "채팅하기" : "참여하기") {
                    Task { await openTopic(meta.topicId) }
                }
            }
        }
    }

    private func openTopic(_ topicId: String) async {
        if let topic = await vm.joinTopic(topicId) {
            showTopics = false
            app.path.append(.topic(topic))
        }
    }

    // MARK: 토픽 목록 시트

    private var topicSheet: some View {
        NavigationStack {
            List(vm.topics) { t in
                Button {
                    Task { await openTopic(t.id) }
                } label: {
                    HStack(spacing: 12) {
                        TopicImage(url: t.imageUrl, category: t.category)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).foregroundStyle(Theme.foreground)
                            Text("\(t.memberCount)명 · \(t.lastMessageAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(Theme.mutedForeground)
                        }
                        Spacer()
                        if !t.isMember {
                            Text("참여하기").font(.caption.weight(.medium)).foregroundStyle(Theme.foreground)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if vm.topics.isEmpty { Text("아직 토픽이 없어요").foregroundStyle(Theme.mutedForeground) } }
            .navigationTitle("진행 중인 토픽")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 입력창

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(vm.readOnly ? "방 범위를 벗어나 읽기만 가능해요" : "메시지 입력", text: $vm.draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border, lineWidth: 1))
                .disabled(vm.readOnly)
            SendButton(enabled: !vm.readOnly && !vm.draft.trimmingCharacters(in: .whitespaces).isEmpty, action: vm.send)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.background)
    }
}

/// 누르면 종이비행기가 오른쪽 위로 날아갔다가 왼쪽 아래에서 돌아옴
private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    @State private var flights = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Flight {
        var shift: CGFloat = 0
        var opacity: Double = 1
    }

    var body: some View {
        Button {
            Haptics.tap()
            if !reduceMotion { flights += 1 }
            action()
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Theme.primaryForeground : Theme.mutedForeground)
                .keyframeAnimator(initialValue: Flight(), trigger: flights) { view, f in
                    view.offset(x: f.shift, y: -f.shift).opacity(f.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.shift) {
                        CubicKeyframe(22, duration: 0.27)
                        MoveKeyframe(-22)
                        CubicKeyframe(0, duration: 0.36)
                    }
                    KeyframeTrack(\.opacity) {
                        CubicKeyframe(0, duration: 0.27)
                        CubicKeyframe(1, duration: 0.36)
                    }
                }
                .frame(width: 38, height: 38)
                .background(Circle().fill(enabled ? Theme.primary : Theme.muted))
                .clipShape(Circle())
                .animation(Motion.settle(), value: enabled)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .disabled(!enabled)
        .accessibilityLabel("보내기")
    }
}
