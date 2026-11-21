import SwiftUI

/// 40pt 원형 아이콘 버튼 (디자인 헤더의 뒤로·설정·공유)
struct CircleIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.secondary))
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// 디자인의 주 버튼 (높이 56, 둥글기 24, 17pt bold)
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isLoading = false
    let action: () -> Void

    var body: some View {
        ShadButton(title: title, variant: .primary, isLoading: isLoading, systemImage: systemImage, action: action)
    }
}

/// 바텀 시트 머리: 제목 + 닫기
struct SheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title).appFont(18, .heavy).foregroundStyle(Theme.foreground)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.foreground)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("닫기")
        }
    }
}

/// 디자인 바텀 시트 모양: 위 둥글기 28, popover 바탕, 손잡이 40×6
struct RippleSheetStyle: ViewModifier {
    var detents: Set<PresentationDetent>

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .top) {
                Capsule().fill(Theme.muted).frame(width: 40, height: 6).padding(.top, 12)
            }
            .presentationDetents(detents)
            .presentationCornerRadius(Theme.Radius.sheet)
            .presentationBackground(Theme.popover)
            .presentationDragIndicator(.hidden)
    }
}

extension View {
    func rippleSheet(detents: Set<PresentationDetent> = [.medium]) -> some View {
        modifier(RippleSheetStyle(detents: detents))
    }
}

/// 토픽방 큰 커버: 카테고리 이미지 + 아래쪽 그늘 + #태그
struct TopicCover: View {
    let topic: TopicOut
    var height: CGFloat = 112
    var tagSize: CGFloat = 36

    var body: some View {
        TopicImage(url: topic.coverUrl ?? topic.imageUrl, category: topic.category, iconFont: .largeTitle)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x0E1118, alpha: 0.05), location: 0.25),
                        .init(color: Color(hex: 0x0E1118, alpha: 0.78), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                Text(TopicTitle.hashtag(topic.title))
                    .appFont(tagSize, .black)
                    .foregroundStyle(Theme.storyForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl))
    }
}

/// 대화 글자 크기 설정 (내 정보·대화 설정 시트 공용). 화면은 라이트로 고정
struct AppearanceControls: View {
    @AppStorage(AppearanceKey.chatSize) private var chatSizeRaw = ChatTextSize.medium.rawValue
    @Environment(AppState.self) private var app

    private var size: ChatTextSize { ChatTextSize(rawValue: chatSizeRaw) ?? .medium }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("화면과 대화")
                .appFont(12, .bold)
                .foregroundStyle(Theme.mutedForeground)
                .padding(.bottom, 12)
            HStack {
                Text("대화 글자 크기").appFont(14, .semibold).foregroundStyle(Theme.foreground)
                Spacer()
                Text(size.label).appFont(12, .semibold).foregroundStyle(Theme.primary)
            }
            Slider(
                value: Binding(
                    get: { Double(ChatTextSize.allCases.firstIndex(of: size) ?? 1) },
                    set: { v in
                        let next = ChatTextSize.allCases[Int(v.rounded())]
                        if next != size { Haptics.select(); chatSizeRaw = next.rawValue }
                    }
                ),
                in: 0...3,
                step: 1
            )
            .tint(Theme.primary)
            .padding(.top, 8)
            .accessibilityLabel("대화 글자 크기")
            HStack {
                ForEach(ChatTextSize.allCases, id: \.self) { s in
                    Text(s.label).appFont(10, .medium).foregroundStyle(Theme.mutedForeground)
                    if s != .extra { Spacer() }
                }
            }
            .padding(.top, 4)

            VStack(alignment: .trailing, spacing: 8) {
                Text(app.me?.nickname ?? "느긋한 곰")
                    .appFont(10)
                    .foregroundStyle(Theme.mutedForeground)
                Text("같은 곳에 있으니까 더 반갑다 👋")
                    .font(AppFont.size(size.points, .medium))
                    .foregroundStyle(Theme.chatOwnForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, bottomTrailingRadius: 12, topTrailingRadius: 24)
                            .fill(Theme.chatOwn)
                    )
                    .animation(Motion.settle(), value: size)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .padding(.top, 20)
        }
    }
}
