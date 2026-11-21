import SwiftUI
import UIKit

/// shadcn/ui neutral 기본 테마 근사치. 디자인이 나오면 여기만 바꾸면 됨.
enum Theme {
    static let background = Color(hex: 0xFFFFFF)
    static let foreground = Color(hex: 0x0A0A0A)
    static let primary = Color(hex: 0x171717)
    static let primaryForeground = Color(hex: 0xFAFAFA)
    static let muted = Color(hex: 0xF5F5F5)
    static let mutedForeground = Color(hex: 0x737373)
    static let border = Color(hex: 0xE5E5E5)
    static let ring = Color(hex: 0xD4D4D4)
    static let destructive = Color(hex: 0xDC2626)
    static let kakao = Color(hex: 0xFEE500)
    static let kakaoLabel = Color(hex: 0x191919)
    static let radius: CGFloat = 10
    static let controlHeight: CGFloat = 52
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - 모션

enum Motion {
    /// 빠르게 나갔다가 부드럽게 멈추는 곡선 (0.22, 1, 0.36, 1)
    static func settle(_ duration: Double = 0.24) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    static let press = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.09)
    static let release = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    static let pop = Animation.spring(response: 0.28, dampingFraction: 0.6)
    static let page = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
    /// 말풍선이 들어올 때: 살짝 튀고 금방 멈춤
    static let bubble = Animation.spring(response: 0.34, dampingFraction: 0.78)
}

extension AnyTransition {
    /// 말풍선 등장: 보낸 쪽 모서리에서 커지며 떠오름
    static func bubbleIn(from anchor: UnitPoint, scale: CGFloat = 0.82) -> AnyTransition {
        .asymmetric(
            insertion: .scale(scale: scale, anchor: anchor)
                .combined(with: .opacity)
                .combined(with: .offset(y: 10)),
            removal: .opacity
        )
    }
}

@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// 누르면 살짝 작아지고 흐려지는 공통 버튼 스타일
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var dim: Double = 0.85

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? dim : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
    }
}

/// 좌우로 흔드는 효과. trigger 값을 바꾸면서 withAnimation(.linear(duration: 0.4))로 감싸서 사용
struct Shake: GeometryEffect {
    var amount: CGFloat = 7
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(animatableData * .pi * shakes * 2), y: 0))
    }
}

/// 화면에 들어올 때 아래에서 살짝 떠오르며 나타남
struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                withAnimation(Motion.settle(0.55).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func shake(_ trigger: Int) -> some View { modifier(Shake(animatableData: CGFloat(trigger))) }
    func riseIn(_ delay: Double = 0) -> some View { modifier(RiseIn(delay: delay)) }
}

// MARK: - 로고

/// 앱 아이콘과 같은 비율의 Ripple 마크 (가운데 점 + 동심원 3개)
struct RippleMark: View {
    var size: CGFloat
    var color: Color = Theme.foreground

    var body: some View {
        Canvas { ctx, canvas in
            let half = canvas.width / 2
            let c = CGPoint(x: half, y: half)
            let rings: [(radius: CGFloat, line: CGFloat)] = [(0.348, 0.031), (0.582, 0.025), (0.816, 0.019)]
            for ring in rings {
                let r = half * ring.radius
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .color(color),
                    lineWidth: max(1.2, half * ring.line)
                )
            }
            let dot = half * 0.117
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)), with: .color(color))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Ripple")
    }
}

/// 로그인 화면용: 마크 바깥으로 물결이 계속 퍼져나감
struct RippleHero: View {
    var markSize: CGFloat = 92
    var spread: CGFloat = 240

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: reduceMotion)) { context in
                Canvas { ctx, canvas in
                    let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                    let t = context.date.timeIntervalSinceReferenceDate
                    let period = 3.2
                    let start = markSize * 0.41
                    let end = canvas.width / 2
                    for i in 0..<3 {
                        let p = ((t / period) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        let eased = 1 - pow(1 - p, 2)
                        let r = start + (end - start) * eased
                        ctx.stroke(
                            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                            with: .color(Theme.foreground.opacity(0.18 * (1 - p))),
                            lineWidth: 1
                        )
                    }
                }
            }
            .frame(width: spread, height: spread)
            .opacity(appeared ? 1 : 0)

            RippleMark(size: markSize)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.82)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

/// 카카오 말풍선 심볼 (viewBox 13 14 22 21)
struct KakaoSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 13) / 22 * rect.width, y: rect.minY + (y - 14) / 21 * rect.height)
        }
        var path = Path()
        path.move(to: p(24.0014, 14))
        path.addCurve(to: p(13, 22.9825), control1: p(17.9241, 14), control2: p(13, 18.0219))
        path.addCurve(to: p(18.1057, 30.5656), control1: p(13, 26.1711), control2: p(15.0368, 28.9728))
        path.addLine(to: p(17.0681, 34.5677))
        path.addCurve(to: p(17.1424, 34.9033), control1: p(17.0295, 34.6871), control2: p(17.0598, 34.8151))
        path.addCurve(to: p(17.3653, 35), control1: p(17.2029, 34.9659), control2: p(17.2855, 35))
        path.addCurve(to: p(17.5607, 34.9289), control1: p(17.4341, 35), control2: p(17.5029, 34.9772))
        path.addLine(to: p(22.0196, 31.8171))
        path.addCurve(to: p(23.9986, 31.9622), control1: p(22.661, 31.911), control2: p(23.3215, 31.9622))
        path.addCurve(to: p(35, 22.9797), control1: p(30.0732, 31.9622), control2: p(35, 27.9403))
        path.addCurve(to: p(24.0014, 14), control1: p(35, 18.0191), control2: p(30.0759, 14))
        path.closeSubpath()
        return path
    }
}

// MARK: - 컴포넌트

struct ShadButton: View {
    enum Variant { case primary, secondary, outline, ghost, destructive }

    let title: String
    var variant: Variant = .primary
    var isLoading = false
    var compact = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(
        title: String,
        variant: Variant = .primary,
        isLoading: Bool = false,
        compact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.isLoading = isLoading
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(size: compact ? 14 : 16, weight: .semibold))
                    .lineLimit(1)
                    .opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(foreground) }
            }
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.horizontal, compact ? 14 : 0)
            .frame(height: Theme.controlHeight)
            .foregroundStyle(isEnabled ? foreground : Theme.mutedForeground)
            .background(isEnabled ? background : disabledBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(variant == .outline ? Theme.border : .clear, lineWidth: 1)
            )
            .animation(Motion.settle(), value: isEnabled)
            .animation(Motion.settle(), value: isLoading)
        }
        .buttonStyle(PressStyle())
        .disabled(isLoading)
    }

    private var foreground: Color {
        switch variant {
        case .primary, .destructive: return Theme.primaryForeground
        default: return Theme.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .primary: return Theme.primary
        case .secondary: return Theme.muted
        case .destructive: return Theme.destructive
        case .outline, .ghost: return .clear
        }
    }

    private var disabledBackground: Color {
        variant == .ghost ? .clear : Theme.muted
    }
}

struct ShadFieldStyle: ViewModifier {
    var focused = false
    var invalid = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(borderColor, lineWidth: focused || invalid ? 1.5 : 1))
            .background(
                RoundedRectangle(cornerRadius: Theme.radius + 3)
                    .stroke(focused ? Theme.muted : .clear, lineWidth: 6)
                    .padding(-1.5)
            )
            .animation(Motion.settle(), value: focused)
            .animation(Motion.settle(), value: invalid)
    }

    private var borderColor: Color {
        if invalid { return Theme.destructive }
        return focused ? Theme.foreground : Theme.border
    }
}

extension View {
    func shadField(focused: Bool = false, invalid: Bool = false) -> some View {
        modifier(ShadFieldStyle(focused: focused, invalid: invalid))
    }
}

struct ShadAvatar: View {
    let url: String?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u, transaction: Transaction(animation: Motion.settle())) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().transition(.opacity)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.border, lineWidth: 1))
    }

    private var placeholder: some View {
        ZStack {
            Theme.muted
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(Theme.mutedForeground)
        }
    }
}

/// 토픽 카테고리 이미지. 서버 이미지를 못 받으면 카테고리 아이콘으로 대신한다
struct TopicImage: View {
    let url: String?
    let category: String
    var iconFont: Font = .title3

    // 크기는 바깥 frame이 정한다. 이미지는 overlay라 scaledToFill이어도 레이아웃을 밀어내지 않는다
    var body: some View {
        Theme.muted
            .overlay {
                Image(systemName: TopicCategory.symbol(category))
                    .font(iconFont)
                    .foregroundStyle(Theme.mutedForeground)
            }
            .overlay {
                if let url, let u = URL(string: url) {
                    AsyncImage(url: u, transaction: Transaction(animation: Motion.settle())) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill().transition(.opacity)
                        }
                    }
                }
            }
            .clipped()
    }
}

struct ShadAvatarStack: View {
    let urls: [String?]
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(Array(urls.prefix(5).enumerated()), id: \.offset) { _, url in
                ShadAvatar(url: url, size: size)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 2))
            }
        }
    }
}

struct ShadCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
    }
}

/// 온보딩 상단: 뒤로가기 + 단계 진행 막대
struct OnboardingHeader: View {
    let step: Int
    let total: Int
    var onBack: (() -> Void)?

    @State private var filled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.foreground)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.9, dim: 0.6))
                    .accessibilityLabel("뒤로")
                }
                Spacer()
                Text("\(step)/\(total)")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.trailing, 20)
            }
            .frame(height: 44)
            .padding(.leading, 8)

            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { i in
                    Capsule()
                        .fill(Theme.border)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.foreground)
                                .scaleEffect(x: i < step || (i == step && filled) ? 1 : 0, anchor: .leading)
                        }
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 20)
        }
        .onAppear {
            withAnimation(Motion.settle(0.7).delay(0.15)) { filled = true }
        }
    }
}

@MainActor
enum Keyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// 입력 화면 뼈대: 위 헤더는 고정, 가운데는 스크롤, 아래 버튼은 키보드 위에 붙음.
/// 키보드가 올라와도 헤더(뒤로가기)가 밀려 올라가지 않음.
/// scrollTarget에 `.id(...)`를 단 뷰의 id를 넣으면 그 뷰가 버튼·키보드 위에 보이도록 스크롤함.
struct FormScaffold<Header: View, Content: View, Footer: View>: View {
    var scrollTarget: Binding<String?> = .constant(nil)
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(
        scrollTarget: Binding<String?> = .constant(nil),
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.scrollTarget = scrollTarget
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollTarget.wrappedValue) { _, id in
                    guard let id else { return }
                    // 새로 나타난 영역이 자리 잡고 키보드가 올라온 뒤에 스크롤
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(320))
                        withAnimation(Motion.settle(0.4)) { proxy.scrollTo(id, anchor: .bottom) }
                        scrollTarget.wrappedValue = nil
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Theme.background)
        }
        .background(Theme.background)
    }
}
