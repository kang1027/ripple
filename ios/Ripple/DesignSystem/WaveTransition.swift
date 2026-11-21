import SwiftUI
import UIKit

/// 방에 들어가거나 인증을 마칠 때 누른 자리에서 물빛 원이 화면을 덮고, 새 화면이 드러나는 전환 (디자인 navigation-wave).
/// 화면이 통째로 바뀌어도 이어지도록 상태를 한곳에 두고, 각 화면 위의 WaveOverlay가 같은 상태를 그린다
@MainActor
@Observable
final class WaveTransition {
    static let shared = WaveTransition()

    private(set) var active = false
    private(set) var origin: CGPoint = .zero
    private(set) var progress: CGFloat = 0
    private(set) var opacity: Double = 0
    /// 마지막으로 누른 자리 (화면 좌표). 원이 여기서 퍼진다
    var lastTap: CGPoint?

    func go(from point: CGPoint? = nil, _ action: @escaping @MainActor () async -> Void) {
        if active || UIAccessibility.isReduceMotionEnabled {
            Task { await action() }
            return
        }
        let screen = Self.screenSize
        origin = point ?? lastTap ?? CGPoint(x: screen.width / 2, y: screen.height * 0.8)
        lastTap = nil
        active = true
        progress = 0
        opacity = 0.6
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.36)) {
            progress = 1
            opacity = 1
        } completion: {
            Task { @MainActor in
                await action()
                // 새 화면이 자리 잡은 뒤에 걷어낸다
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.easeOut(duration: 0.22)) {
                    self.opacity = 0
                } completion: {
                    self.active = false
                    self.progress = 0
                }
            }
        }
    }

    private static var screenSize: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.bounds.size ?? CGSize(width: 393, height: 852)
    }
}

/// 전환 원을 그리는 층. 화면 맨 위에 얹는다
struct WaveOverlay: View {
    var body: some View {
        let wave = WaveTransition.shared
        GeometryReader { geo in
            if wave.active {
                let frame = geo.frame(in: .global)
                let local = CGPoint(x: wave.origin.x - frame.minX, y: wave.origin.y - frame.minY)
                let radius = hypot(max(local.x, frame.width - local.x), max(local.y, frame.height - local.y))
                Circle()
                    .fill(Theme.primary)
                    .frame(width: radius * 2, height: radius * 2)
                    .scaleEffect(max(wave.progress, 0.001))
                    .position(local)
                    .opacity(wave.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(wave.active)
        .accessibilityHidden(true)
    }
}

extension View {
    /// 누른 자리를 기억해 두었다가 전환 원의 시작점으로 쓴다
    func recordsWaveTaps() -> some View {
        simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                WaveTransition.shared.lastTap = value.location
            }
        )
    }

    /// 전환 원을 화면 위에 얹고, 누른 자리를 기억한다
    func waveOverlay() -> some View {
        recordsWaveTaps().overlay { WaveOverlay() }
    }
}
