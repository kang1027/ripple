import SwiftUI
import UIKit

/// Ripple 디자인 토큰 (Lovable 디자인 styles.css의 oklch 값을 sRGB로 계산한 값).
/// 색은 라이트·다크에 따라 바뀌는 동적 색이다.
enum Theme {
    static let background = Color(light: 0xFFFFFF, dark: 0x0C0D10)
    static let foreground = Color(light: 0x151B24, dark: 0xF0F2F5)
    static let card = Color(light: 0xF5F7F9, dark: 0x16181D)
    static let popover = Color(light: 0xFFFFFF, dark: 0x14161A)
    static let primary = Color(light: 0x007DF3, dark: 0x3AB0FF)
    static let primaryForeground = Color(light: 0xFFFFFF, dark: 0x080E16)
    static let primarySoft = Color(light: 0xE0F1FF, dark: 0x0F2840)
    static let secondary = Color(light: 0xEDF0F4, dark: 0x202226)
    static let muted = Color(light: 0xE4E8ED, dark: 0x2C2E32)
    static let mutedForeground = Color(light: 0x757B83, dark: 0x9B9EA5)
    static let border = Color(light: 0xE2E5E8, dark: 0x2E3036)
    static let ring = primary
    static let destructive = Color(hex: 0xEE343B)
    static let destructiveForeground = Color(hex: 0xFFFFFF)
    static let chatOwn = primary
    static let chatOwnForeground = primaryForeground
    static let chatOther = Color(light: 0xEDF0F4, dark: 0x202226)
    static let storyForeground = Color(hex: 0xFFFFFF)
    static let kakao = Color(hex: 0xFEE500)
    static let kakaoLabel = Color(hex: 0x191919)

    /// 홈 수영장
    enum Water {
        static let deep = Color(light: 0x0061AC, dark: 0x002C58)
        static let shallow = Color(light: 0x3EA5E3, dark: 0x0069A1)
        static let highlight = Color(light: 0xFFFFFF, dark: 0x7EBCD0)
        static let floor = Color(light: 0x0088CB, dark: 0x004880)
        static let lettering = Color(light: 0xE3F5FF, dark: 0xC5E3F5)
        static let grout = Color(light: 0x8BBFDE, lightAlpha: 0.18, dark: 0x5197C6, darkAlpha: 0.25)

        /// 셰이더에 넘길 원본 sRGB 값 (Three.js와 같이 변환 없이 계산)
        static func raw(_ scheme: ColorScheme) -> (deep: UInt32, shallow: UInt32, highlight: UInt32) {
            scheme == .dark ? (0x002C58, 0x0069A1, 0x7EBCD0) : (0x0061AC, 0x3EA5E3, 0xFFFFFF)
        }
    }

    /// 둥글기 (디자인은 --radius 16px 기준으로 단계를 다시 정의함)
    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 14
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let sheet: CGFloat = 28
    }

    static let radius: CGFloat = Radius.xxl
    static let controlHeight: CGFloat = 56
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            let alpha = traits.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}

/// SwiftUI 글꼴. Pretendard가 앱에 들어 있으면 그걸 쓰고, 없으면 시스템 글꼴로 떨어진다
enum AppFont {
    static func size(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .black: name = "Pretendard-Black"
        case .heavy: name = "Pretendard-ExtraBold"
        case .bold: name = "Pretendard-Bold"
        case .semibold: name = "Pretendard-SemiBold"
        case .medium: name = "Pretendard-Medium"
        default: name = "Pretendard-Regular"
        }
        if UIFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: weight)
    }
}

extension View {
    /// 디자인 글자 크기·굵기 (pt)
    func appFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(AppFont.size(size, weight))
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
                            with: .color(Theme.primary.opacity(0.5 * (1 - p))),
                            lineWidth: 2
                        )
                    }
                }
            }
            .frame(width: spread, height: spread)
            .opacity(appeared ? 1 : 0)

            Image("RippleLogo")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .offset(y: -markSize * 0.2)
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
    var systemImage: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(
        title: String,
        variant: Variant = .primary,
        isLoading: Bool = false,
        compact: Bool = false,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.isLoading = isLoading
        self.compact = compact
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).font(.system(size: compact ? 13 : 15, weight: .bold)) }
                    Text(title).appFont(compact ? 14 : 17, .bold).lineLimit(1)
                }
                .opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(foreground) }
            }
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.horizontal, compact ? 16 : 0)
            .frame(height: Theme.controlHeight)
            .foregroundStyle(isEnabled ? foreground : Theme.mutedForeground)
            .background(isEnabled ? background : disabledBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xxl)
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
        case .primary: return Theme.primaryForeground
        case .destructive: return Theme.destructiveForeground
        default: return Theme.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .primary: return Theme.primary
        case .secondary: return Theme.secondary
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
            .font(AppFont.size(18, .semibold))
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 20)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xxl).fill(Theme.secondary))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xxl).stroke(borderColor, lineWidth: 1))
            .animation(Motion.settle(), value: focused)
            .animation(Motion.settle(), value: invalid)
    }

    private var borderColor: Color {
        if invalid { return Theme.destructive }
        return focused ? Theme.primary : .clear
    }
}

extension View {
    func shadField(focused: Bool = false, invalid: Bool = false) -> some View {
        modifier(ShadFieldStyle(focused: focused, invalid: invalid))
    }
}

/// 원격 이미지 메모리 캐시. 실패하면 잠깐 쉬었다가 두 번 더 받아 본다
@MainActor
final class ImageStore {
    static let shared = ImageStore()
    private let cache = NSCache<NSURL, UIImage>()

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
            if Task.isCancelled { return nil }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        return nil
    }
}

/// AsyncImage는 LazyVStack 안에서 로딩이 취소되면 실패 상태로 굳어서 다시 안 받는다.
/// 이건 화면에 다시 나타날 때마다(.task) 캐시를 보고 없으면 다시 받는다
struct RemoteImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        ZStack {
            if let image = loaded?.url == url ? loaded?.image : ImageStore.shared.cached(url) {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard ImageStore.shared.cached(url) == nil, let image = await ImageStore.shared.load(url) else { return }
            withAnimation(Motion.settle()) { loaded = (url, image) }
        }
    }
}

struct ShadAvatar: View {
    let url: String?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                RemoteImage(url: u) { placeholder }
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
                    RemoteImage(url: u) { Color.clear }
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
