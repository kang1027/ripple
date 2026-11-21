import SwiftUI

/// 화면 모드·대화 글자 크기 (디자인 appearance.ts). 기기에 저장한다
enum AppearanceKey {
    static let theme = "ripple.theme"
    static let chatSize = "ripple.chatSize"
}

enum ThemeMode: String, CaseIterable {
    case light, dark

    var scheme: ColorScheme { self == .dark ? .dark : .light }
    var label: String { self == .dark ? "다크" : "라이트" }
    var symbol: String { self == .dark ? "moon" : "sun.max" }
}

enum ChatTextSize: String, CaseIterable {
    case small, medium, large, extra

    var label: String {
        switch self {
        case .small: return "작게"
        case .medium: return "기본"
        case .large: return "크게"
        case .extra: return "더 크게"
        }
    }

    var points: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 14
        case .large: return 16
        case .extra: return 18
        }
    }
}

/// 홈 오른쪽 위 라이트·다크 전환 버튼
struct ThemeToggleButton: View {
    @AppStorage(AppearanceKey.theme) private var themeRaw = ThemeMode.light.rawValue

    var body: some View {
        let mode = ThemeMode(rawValue: themeRaw) ?? .light
        Button {
            Haptics.select()
            withAnimation(Motion.settle(0.3)) {
                themeRaw = (mode == .light ? ThemeMode.dark : .light).rawValue
            }
        } label: {
            Image(systemName: mode == .light ? "moon" : "sun.max")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.secondary))
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .accessibilityLabel(mode == .light ? "다크 모드 켜기" : "라이트 모드 켜기")
    }
}

/// 토픽·리플 커버 그라데이션 (디자인 --wave-1…5, 145°)
struct CoverGradient: View {
    var style: Int = 2
    var pattern = true

    private static let stops: [(UInt32, UInt32)] = [
        (0xDE25B4, 0x562ACF), (0x009FEF, 0x213BE3), (0x00B892, 0x005871), (0xFF753E, 0xCC002B), (0xC060FC, 0x442DBD),
    ]

    var body: some View {
        let pair = Self.stops[(max(style, 1) - 1) % Self.stops.count]
        LinearGradient(
            colors: [Color(hex: pair.0), Color(hex: pair.1)],
            startPoint: UnitPoint(x: 0.21, y: 0.09),
            endPoint: UnitPoint(x: 0.79, y: 0.91)
        )
        .overlay { if pattern { RipplePattern() } }
    }
}

/// 오른쪽 위 모서리에서 퍼지는 물결 줄무늬 (디자인 .ripple-pattern)
struct RipplePattern: View {
    var body: some View {
        Canvas { ctx, size in
            let origin = CGPoint(x: size.width, y: 0)
            let reach = hypot(size.width, size.height)
            var r: CGFloat = 30
            while r < reach + 30 {
                let rect = CGRect(x: origin.x - r, y: origin.y - r * 0.82, width: r * 2, height: r * 1.64)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.22)), lineWidth: 2)
                r += 30
            }
        }
        .allowsHitTesting(false)
    }
}
