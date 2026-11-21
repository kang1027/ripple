import SwiftUI

// MARK: - 말풍선 한 줄

/// 사람 메시지 한 줄. 캐릭터가 화면 가장자리에서 빼꼼 나오고, 말풍선을 왼쪽으로 밀면 답장한다
struct MessageRow: View {
    let nickname: String
    let isMine: Bool
    let avatar: Avatar
    let text: String
    let reply: ReplyTarget?
    let textSize: CGFloat
    var sending = false
    var failed = false
    var onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    let onLongPress: (() -> Void)?
    let onQuoteTap: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var crossed = false
    private let replyThreshold: CGFloat = 48

    var body: some View {
        ZStack(alignment: isMine ? .topTrailing : .topLeading) {
            CharacterView(avatar: avatar, peek: isMine ? .left : .right)
                .frame(width: 42, height: 46)
                .offset(x: isMine ? 17 : -17, y: 4)
                .allowsHitTesting(false)

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Text(isMine ? "\(nickname) · 나" : nickname)
                    .appFont(11, .semibold)
                    .foregroundStyle(Theme.mutedForeground)
                HStack(alignment: .bottom, spacing: 6) {
                    if failed {
                        Button {
                            Haptics.tap()
                            onRetry?()
                        } label: {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.destructive)
                        }
                        .buttonStyle(PressStyle(scale: 0.85))
                        .accessibilityLabel("다시 보내기")
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                    bubble
                }
            }
            .padding(.leading, isMine ? 20 : 44)
            .padding(.trailing, isMine ? 44 : 20)
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
            .offset(x: dragX)
            .overlay(alignment: .trailing) {
                if dragX < -8 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(crossed ? Theme.primary : Theme.mutedForeground)
                        .padding(.trailing, 12)
                        .opacity(min(1, Double(-dragX / replyThreshold)))
                }
            }
        }
        .frame(minHeight: 56, alignment: .top)
        .animation(Motion.settle(), value: sending)
        .animation(Motion.pop, value: failed)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reply {
                Button(action: onQuoteTap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reply.nickname).appFont(11, .semibold)
                        Text(reply.body).appFont(12).opacity(0.75).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .fill(isMine ? Color.white.opacity(0.15) : Theme.background.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(reply.nickname)의 원문 보기")
            }
            Text(text)
                .font(AppFont.size(textSize, isMine ? .medium : .regular))
                .lineSpacing(textSize * 0.3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isMine ? Theme.chatOwnForeground : Theme.foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: isMine ? 24 : 14,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: isMine ? 14 : 24,
                topTrailingRadius: 24
            )
            .fill(isMine ? Theme.chatOwn : Theme.chatOther)
        )
        .opacity(sending ? 0.55 : 1)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.45) {
            guard let onLongPress else { return }
            Haptics.tap()
            onLongPress()
        }
        .simultaneousGesture(swipe)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "답장하기") { onReply?() }
    }

    /// 왼쪽으로만 민다. 오른쪽 밀기는 화면 뒤로 가기에 양보한다
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                guard onReply != nil else { return }
                let dx = v.translation.width, dy = v.translation.height
                guard dx < 0, abs(dx) > abs(dy) * 1.5 else { return }
                dragX = max(-64, dx)
                let over = dx <= -replyThreshold
                if over != crossed {
                    crossed = over
                    if over { Haptics.select() }
                }
            }
            .onEnded { _ in
                if crossed { onReply?() }
                crossed = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
            }
    }
}

// MARK: - 봇 답장

/// Ripple 봇이 주제를 꺼낸 메시지에 답장하며 토픽방을 알려 주는 말풍선
struct BotReplyRow: View {
    let meta: TopicMeta
    let quote: ReplyTarget?
    let isMember: Bool
    let memberCount: Int
    let textSize: CGFloat
    let onOpen: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("RippleLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.primarySoft))
                .offset(x: 4, y: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Ripple").appFont(11, .semibold).foregroundStyle(Theme.mutedForeground)
                    Text("봇")
                        .appFont(10, .bold)
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Theme.primarySoft))
                }
                VStack(alignment: .leading, spacing: 0) {
                    if let quote {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quote.nickname).appFont(11, .semibold)
                            Text(quote.body).appFont(12).opacity(0.75).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.secondary))
                        .padding(.bottom, 8)
                    }
                    Text(message)
                        .font(AppFont.size(textSize))
                        .lineSpacing(textSize * 0.3)
                        .fixedSize(horizontal: false, vertical: true)
                    if meta.reminder == true { miniCard } else { fullCard }
                }
                .foregroundStyle(Theme.foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 24, bottomTrailingRadius: 24, topTrailingRadius: 24)
                        .fill(Theme.card)
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 24, bottomTrailingRadius: 24, topTrailingRadius: 24)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .padding(.leading, 44)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String { TopicTitle.hashtag(meta.title) }

    private var message: String {
        if meta.reminder == true { return "이 얘기는 토픽방에서 이어지고 있어요." }
        return "'\(meta.title)' 얘기가 이어지고 있어요. 따로 이야기할 수 있게 토픽방을 열었어요."
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopicImage(url: meta.imageUrl, category: meta.category, iconFont: .title2)
                .frame(maxWidth: .infinity)
                .aspectRatio(2, contentMode: .fit)
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(15, .heavy).foregroundStyle(Theme.foreground)
                Text(meta.summary.isEmpty ? "\(memberCount)명 참여 중" : "\(meta.summary) · \(memberCount)명 참여 중")
                    .appFont(12)
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            Button {
                Haptics.tap()
                onOpen()
            } label: {
                Text(isMember ? "채팅하기" : "참여하기")
                    .appFont(14, .heavy)
                    .foregroundStyle(Theme.primaryForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.xl).fill(Theme.primary))
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(Theme.border, lineWidth: 1))
        .padding(.top, 10)
    }

    private var miniCard: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            HStack(spacing: 10) {
                TopicImage(url: meta.imageUrl, category: meta.category)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).appFont(13, .heavy).foregroundStyle(Theme.foreground)
                    Text("\(memberCount)명 참여 중").appFont(11).foregroundStyle(Theme.mutedForeground)
                }
                Spacer(minLength: 0)
                Text(isMember ? "채팅하기" : "참여하기")
                    .appFont(12, .bold)
                    .foregroundStyle(Theme.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .padding(.top, 8)
    }
}

// MARK: - 길게 누르기 시트

/// 답장·신고·차단. 처리 결과를 잠깐 보여준 뒤 닫힌다
struct MessageActionSheet: View {
    let message: MessageOut
    let isMine: Bool
    let onReply: () -> Void
    let onReport: () async -> Void
    let onBlock: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var done: String?
    @State private var closing: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let done {
                Text(done)
                    .appFont(16, .semibold)
                    .foregroundStyle(Theme.foreground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .transition(.opacity)
            } else {
                Text("\(message.sender?.nickname ?? "알 수 없음")님의 메시지")
                    .appFont(14)
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                row("답장하기", "arrowshape.turn.up.left", color: Theme.foreground) {
                    dismiss()
                    onReply()
                }
                if !isMine {
                    row("신고하기", "exclamationmark.shield", color: Theme.destructive) {
                        await onReport()
                        finish("신고가 접수됐어요")
                    }
                    row("차단하기", "nosign", color: Theme.foreground) {
                        await onBlock()
                        finish("\(message.sender?.nickname ?? "")님을 차단했어요")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .rippleSheet(detents: [.height(isMine ? 170 : 290)])
        .animation(Motion.settle(), value: done)
        .onDisappear { closing?.cancel() }
    }

    private func row(_ title: String, _ icon: String, color: Color, action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).frame(width: 22)
                Text(title).appFont(14, .semibold)
                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98, dim: 0.6))
    }

    private func finish(_ text: String) {
        Haptics.success()
        done = text
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { dismiss() }
        }
    }
}

// MARK: - 대화 설정 시트

/// "내게 편한 대화": 글자 크기, 동네 리플에서는 방 나가기도
struct ChatSettingsSheet: View {
    var onLeave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLeave = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "내게 편한 대화") { dismiss() }
                AppearanceControls()
                    .padding(.top, 24)
                if onLeave != nil {
                    Button {
                        confirmLeave = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 16, weight: .medium))
                            Text("방 나가기").appFont(14, .semibold)
                            Spacer()
                        }
                        .foregroundStyle(Theme.destructive)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.98, dim: 0.6))
                    .padding(.top, 8)
                }
                ShadButton(title: "완료", systemImage: "checkmark") { dismiss() }
                    .padding(.top, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .rippleSheet(detents: [.large])
        .alert("방에서 나갈까요?", isPresented: $confirmLeave) {
            Button("취소", role: .cancel) {}
            Button("나가기", role: .destructive) {
                dismiss()
                onLeave?()
            }
        } message: {
            Text("다시 가까이 와서 참여하면 들어올 수 있어요")
        }
    }
}

// MARK: - 스토리 공유

/// 토픽방을 9:16 스토리 카드로 만들어 공유한다
struct StoryShareView: View {
    let topic: TopicOut
    let place: String
    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?
    @State private var rendered: Image?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                card
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
                Text("지금 여기서 시작된 이야기")
                    .appFont(14)
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.top, 24)
                Spacer()
                Group {
                    if let rendered {
                        ShareLink(item: rendered, preview: SharePreview(TopicTitle.hashtag(topic.title), image: rendered)) {
                            Text("스토리에 공유하기")
                                .appFont(17, .bold)
                                .foregroundStyle(Theme.primaryForeground)
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.controlHeight)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.xxl).fill(Theme.primary))
                        }
                    } else {
                        ShadButton(title: "카드 만드는 중", isLoading: true) {}
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
            CircleIconButton(systemName: "xmark", label: "공유 닫기") { dismiss() }
                .padding(20)
        }
        .task { await prepare() }
    }

    private var card: some View {
        StoryCard(topic: topic, place: place, photo: photo)
            .frame(width: 224, height: 398)
    }

    @MainActor
    private func prepare() async {
        if let s = topic.coverUrl ?? topic.imageUrl, let url = URL(string: s) {
            photo = await ImageStore.shared.load(url)
        }
        let renderer = ImageRenderer(content: StoryCard(topic: topic, place: place, photo: photo).frame(width: 224, height: 398))
        renderer.scale = 4
        if let ui = renderer.uiImage { rendered = Image(uiImage: ui) }
    }
}

private struct StoryCard: View {
    let topic: TopicOut
    let place: String
    let photo: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverGradient(style: 2, pattern: photo == nil)
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            }
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x0E1118, alpha: 0.05), location: 0.25),
                    .init(color: Color(hex: 0x0E1118, alpha: 0.78), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image("RippleLogo").renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
                    Text("Ripple").appFont(12, .black)
                }
                Spacer()
                Text(TopicTitle.hashtag(topic.title))
                    .appFont(44, .black)
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                Text("\(topic.lastMessageAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))\n\(place) · \(topic.memberCount)명")
                    .appFont(11, .semibold)
                    .padding(.top, 8)
            }
            .foregroundStyle(Theme.storyForeground)
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet))
        .environment(\.colorScheme, .light)
    }
}
