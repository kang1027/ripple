import SwiftUI

enum ChatKind: Hashable {
    case room(RoomOut)
    case topic(TopicOut)
}

/// 답장 대상 (서버가 reply 필드를 내려주기 전에는 보낼 때 고른 메시지로 화면에만 그린다)
struct ReplyTarget: Hashable {
    let id: Int
    let nickname: String
    let body: String
}

extension ReplyTarget {
    init?(_ ref: ReplyRef?) {
        guard let ref else { return nil }
        self.init(id: ref.id, nickname: ref.nickname ?? "알 수 없음", body: ref.body)
    }
}

/// 보냈지만 서버가 아직 돌려주지 않은 내 메시지
struct PendingMessage: Hashable {
    let clientId: String
    let body: String
    var reply: ReplyTarget?
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
    var replyTo: ReplyTarget?
    /// 내가 보낸 메시지의 답장 대상. 서버가 reply를 돌려주기 전까지 말풍선에 인용을 그리는 데 쓴다
    var sentReplies: [String: ReplyTarget] = [:]
    /// 아래쪽을 보고 있지 않을 때 새로 온 메시지 수
    var unseen = 0
    var atBottom = true

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

    var topic: TopicOut? {
        if case .topic(let t) = kind { return t }
        return nil
    }

    var items: [ChatItem] {
        messages.map { ChatItem(id: $0.clientId ?? "m\($0.id)", message: $0, pending: nil) }
            + pending.map { ChatItem(id: $0.clientId, message: nil, pending: $0) }
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
        let reply = replyTo
        draft = ""
        replyTo = nil
        if let reply { sentReplies[cid] = reply }
        withAnimation(Motion.bubble) { pending.append(PendingMessage(clientId: cid, body: text, reply: reply)) }
        transmit(cid, text, reply: reply)
    }

    func retry(_ item: PendingMessage) {
        guard let i = pending.firstIndex(where: { $0.clientId == item.clientId }) else { return }
        withAnimation(Motion.settle()) { pending[i].failed = false }
        transmit(item.clientId, item.body, reply: item.reply)
    }

    /// 보내고 8초 안에 서버가 돌려주지 않으면 실패로 표시
    private func transmit(_ cid: String, _ text: String, reply: ReplyTarget?) {
        var payload: [String: Any] = ["type": "send", "body": text, "client_id": cid]
        if let reply { payload["reply_to"] = reply.id }
        ws.send(payload)
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
                let mine = m.clientId.map { cid in pending.contains { $0.clientId == cid } } ?? false
                withAnimation(Motion.bubble) {
                    if let cid = m.clientId { pending.removeAll { $0.clientId == cid } }
                    messages.append(m)
                }
                if !mine && !atBottom { unseen += 1 }
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceKey.chatSize) private var chatSizeRaw = ChatTextSize.medium.rawValue
    @State private var vm: ChatViewModel
    @State private var showTopics = false
    @State private var showSettings = false
    @State private var showShare = false
    @State private var actionTarget: MessageOut?
    @State private var jumpHighlight: Int?
    @State private var notice: String?
    @State private var myAvatar = AvatarStore.load()
    @FocusState private var inputFocused: Bool

    init(kind: ChatKind) {
        _vm = State(initialValue: ChatViewModel(kind: kind))
    }

    private var chatSize: CGFloat { (ChatTextSize(rawValue: chatSizeRaw) ?? .medium).points }

    var body: some View {
        VStack(spacing: 0) {
            header
            messagesList
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { noticeView }
        .sheet(isPresented: $showTopics) { topicSheet }
        .sheet(isPresented: $showSettings) {
            ChatSettingsSheet(onLeave: isRoom ? { Task { await leaveRoom() } } : nil)
        }
        .sheet(item: $actionTarget) { m in
            MessageActionSheet(
                message: m,
                isMine: m.sender?.id == app.me?.id,
                onReply: { startReply(m) },
                onReport: { await vm.report(m) },
                onBlock: { if let id = m.sender?.id { await vm.block(id) } }
            )
        }
        .fullScreenCover(isPresented: $showShare) {
            if let topic = vm.topic { StoryShareView(topic: topic, place: vm.room?.areaName ?? "") }
        }
        .task {
            TokenStoreUser.id = app.me?.id
            myAvatar = app.me?.avatar ?? AvatarStore.load()
            await vm.load()
        }
        .onDisappear {
            Keyboard.dismiss()
            vm.disconnect()
        }
    }

    private var isRoom: Bool { if case .room = vm.kind { return true } else { return false } }

    // MARK: 헤더

    private var header: some View {
        HStack(spacing: 12) {
            CircleIconButton(systemName: "arrow.left", label: "뒤로") { dismiss() }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .appFont(17, .heavy)
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .appFont(12)
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if isRoom {
                    CircleIconButton(systemName: "list.bullet", label: "진행 중인 토픽") {
                        Task { await vm.reloadTopics() }
                        showTopics = true
                    }
                }
                CircleIconButton(systemName: "slider.horizontal.3", label: "대화 화면 설정") { showSettings = true }
                if !isRoom {
                    CircleIconButton(systemName: "square.and.arrow.up", label: "방 공유") { showShare = true }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var title: String {
        if let t = vm.topic { return TopicTitle.hashtag(t.title) }
        return "\(RoomName.short(vm.room?.areaName)) 리플"
    }

    private var subtitle: String? {
        if isRoom { return "\(vm.room?.memberCount ?? 0)명 · 지금 이곳에서 나누는 이야기" }
        return nil
    }

    // MARK: 메시지 목록

    private var messagesList: some View {
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let topic = vm.topic { topicIntro(topic) }
                    ForEach(vm.items) { item in
                        itemRow(item)
                            .id(item.id)
                            .background(jumpHighlight != nil && item.message?.id == jumpHighlight ? Theme.primarySoft : .clear)
                            .animation(.easeOut(duration: 1.2), value: jumpHighlight)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { vm.atBottom = true; vm.unseen = 0 }
                        .onDisappear { vm.atBottom = false }
                }
                .padding(.vertical, 12)
                // 대화가 짧으면 위에서부터 쌓이고, 길어지면 아래에 붙는다
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .clipped()
            // 대화 목록 어디를 눌러도 키보드를 닫는다 (버튼은 그대로 눌림)
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            // 키보드가 올라와도 마지막 메시지가 아래에 붙어 있게
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.items.count) { old, new in
                guard new > old, let last = vm.items.last else { return }
                // 내가 보냈거나 이미 아래를 보고 있을 때만 따라 내려간다
                if last.pending != nil || vm.atBottom {
                    withAnimation(Motion.bubble) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: jumpRequest) { _, id in
                guard let id else { return }
                withAnimation(Motion.settle(0.4)) { proxy.scrollTo(id, anchor: .center) }
                jumpRequest = nil
            }
            .overlay(alignment: .bottom) {
                if vm.unseen > 0 {
                    Button {
                        withAnimation(Motion.settle(0.4)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        vm.unseen = 0
                    } label: {
                        HStack(spacing: 4) {
                            Text("새 메시지 \(vm.unseen)개")
                            Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                        }
                        .appFont(12, .bold)
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.foreground))
                    }
                    .buttonStyle(PressStyle())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.settle(), value: vm.unseen > 0)
        }
        }
    }

    @State private var jumpRequest: String?

    private func topicIntro(_ topic: TopicOut) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TopicCover(topic: topic, height: 112)
            Text("\(topic.createdAt.map { "생성 " + DateText.full($0) } ?? (vm.room?.areaName ?? "")) · \(topic.memberCount)명")
                .appFont(12, .medium)
                .foregroundStyle(Theme.mutedForeground)
                .padding(.top, 12)
            HStack(spacing: 4) {
                Image(systemName: "mappin").font(.system(size: 10, weight: .semibold))
                Text("\(RoomName.short(topic.placeName ?? vm.room?.areaName))에서 시작된 \(TopicTitle.hashtag(topic.title)) 이야기")
            }
            .appFont(12)
            .foregroundStyle(Theme.mutedForeground)
            .padding(.top, 4)
            Text("장소를 떠나도 계속 이야기할 수 있어요")
                .appFont(12, .semibold)
                .foregroundStyle(Theme.primary)
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// 보내는 중(pending)과 보낸 내 메시지는 같은 분기로 그려야 확인될 때 말풍선이 다시 튀지 않음
    @ViewBuilder
    private func itemRow(_ item: ChatItem) -> some View {
        if let p = item.pending {
            MessageRow(
                nickname: myNickname, isMine: true, avatar: myAvatar, text: p.body, reply: p.reply,
                textSize: chatSize, sending: !p.failed, failed: p.failed,
                onRetry: { vm.retry(p) }, onReply: nil, onLongPress: nil, onQuoteTap: { jump(to: p.reply) }
            )
            .transition(.bubbleIn(from: .bottomTrailing))
        } else if let m = item.message {
            row(m, item: item)
        }
    }

    private var myNickname: String { app.me?.nickname ?? "나" }

    @ViewBuilder
    private func row(_ m: MessageOut, item: ChatItem) -> some View {
        if m.type == MessageType.topicCard, let meta = m.meta {
            BotReplyRow(
                meta: meta,
                quote: ReplyTarget(m.reply),
                isMember: vm.isMember(meta.topicId),
                memberCount: vm.topics.first { $0.id == meta.topicId }?.memberCount ?? meta.memberCount,
                textSize: chatSize
            ) {
                Task { await openTopic(meta.topicId) }
            }
            .transition(.bubbleIn(from: .bottomLeading, scale: 0.9))
        } else if m.type == MessageType.system || m.sender == nil {
            Text(m.body)
                .appFont(12)
                .foregroundStyle(Theme.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .transition(.opacity)
        } else {
            let mine = m.sender?.id == app.me?.id
            let sender = m.sender
            let reply = ReplyTarget(m.reply) ?? (mine ? m.clientId.flatMap { vm.sentReplies[$0] } : nil)
            MessageRow(
                nickname: sender?.nickname ?? "알 수 없음",
                isMine: mine,
                avatar: mine ? myAvatar : (sender?.avatar ?? Avatar.derived(from: sender?.id ?? "unknown")),
                text: m.body,
                reply: reply,
                textSize: chatSize,
                onReply: { startReply(m) },
                onLongPress: { actionTarget = m },
                onQuoteTap: { jump(to: reply) }
            )
            .transition(.bubbleIn(from: mine ? .bottomTrailing : .bottomLeading))
        }
    }

    private func startReply(_ m: MessageOut) {
        guard !vm.readOnly else { return }
        Haptics.select()
        vm.replyTo = ReplyTarget(id: m.id, nickname: m.sender?.nickname ?? "알 수 없음", body: m.body)
        inputFocused = true
    }

    private func jump(to reply: ReplyTarget?) {
        guard let reply else { return }
        guard let target = vm.messages.first(where: { $0.id == reply.id }) else {
            show("원문을 볼 수 없어요")
            return
        }
        jumpRequest = target.clientId ?? "m\(target.id)"
        jumpHighlight = target.id
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            jumpHighlight = nil
        }
    }

    private func openTopic(_ topicId: String) async {
        if let topic = await vm.joinTopic(topicId) {
            showTopics = false
            app.path.append(.topic(topic))
        }
    }

    private func leaveRoom() async {
        await vm.leave()
        app.path.removeAll()
    }

    // MARK: 알림 한 줄

    @ViewBuilder
    private var noticeView: some View {
        if let notice {
            Text(notice)
                .appFont(13, .semibold)
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(Capsule().fill(Theme.foreground))
                .padding(.top, 72)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func show(_ text: String) {
        withAnimation(Motion.settle()) { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Motion.settle()) { if notice == text { notice = nil } }
        }
    }

    // MARK: 토픽 목록 시트

    private var topicSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "진행 중인 토픽") { showTopics = false }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(vm.topics) { t in
                        Button { Task { await openTopic(t.id) } } label: {
                            TopicRoomRow(topic: t, place: vm.room?.areaName)
                        }
                        .buttonStyle(PressStyle(scale: 0.98))
                    }
                    if vm.topics.isEmpty {
                        EmptyState(title: "아직 토픽이 없어요", message: "대화에서 같은 이야기가 이어지면 Ripple 봇이 토픽방을 열어 줘요")
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .rippleSheet(detents: [.medium, .large])
    }

    // MARK: 입력창

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(spacing: 0) {
                    if let reply = vm.replyTo {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(reply.nickname)에게 답장")
                                    .appFont(11, .semibold)
                                    .foregroundStyle(Theme.foreground)
                                Text(reply.body)
                                    .appFont(12)
                                    .foregroundStyle(Theme.mutedForeground)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                withAnimation(Motion.settle()) { vm.replyTo = nil }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.mutedForeground)
                                    .frame(width: 28, height: 28)
                            }
                            .accessibilityLabel("답장 취소")
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        .padding(.horizontal, 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    TextField(vm.readOnly ? "범위를 벗어나서 읽기만 할 수 있어요" : "메시지 보내기", text: $vm.draft, axis: .vertical)
                        .font(AppFont.size(chatSize))
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                        .frame(minHeight: 48)
                        .disabled(vm.readOnly)
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.xxl).fill(Theme.secondary))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.xxl)
                        .stroke(inputFocused ? Theme.primary : .clear, lineWidth: 1)
                )
                .animation(Motion.settle(), value: vm.replyTo)
                SendButton(enabled: !vm.readOnly && !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: vm.send)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.background)
    }
}

/// 동네 이름에서 "근처"를 뗀 짧은 이름 ("홍지동 근처" → "홍지동")
enum RoomName {
    static func short(_ area: String?) -> String {
        guard let area, !area.isEmpty else { return "이곳" }
        let trimmed = area.replacingOccurrences(of: " 근처", with: "")
        return trimmed == "이" ? "이곳" : trimmed
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
            Image(systemName: "paperplane")
                .font(.system(size: 19, weight: .semibold))
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
                .frame(width: 48, height: 48)
                .background(Circle().fill(enabled ? Theme.primary : Theme.muted))
                .clipShape(Circle())
                .animation(Motion.settle(), value: enabled)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .disabled(!enabled)
        .accessibilityLabel("메시지 보내기")
    }
}
