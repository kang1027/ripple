import SwiftUI

/// 위치 권한 안내 (디자인 Permission 화면). 아직 위치를 물어보지 않은 사람에게 홈에서 한 번 보여준다
struct LocationIntroView: View {
    let onAllow: () -> Void
    let onLater: () -> Void
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .stroke(Theme.primary.opacity(0.5), lineWidth: 2)
                        .background(Circle().fill(Theme.primary.opacity(0.05)))
                        .frame(width: 240, height: 240)
                        .scaleEffect(pulse ? 1 : 0.1)
                        .opacity(pulse ? 0 : 0.8)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 3.2).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                            value: pulse
                        )
                        .offset(y: 12)
                }
                Image("RippleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .offset(y: -12)
                Text("Ripple")
                    .appFont(32, .bold)
                    .foregroundStyle(Theme.foreground)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 224)
            .padding(.top, 24)

            Text("지금 여기 있는\n사람들과 이어지려면")
                .appFont(30, .heavy)
                .foregroundStyle(Theme.foreground)
                .lineSpacing(4)
                .padding(.top, 32)
            Text("정확한 위치는 근처에 누가 있는지 확인할 때만 써요. 위치는 잠깐만 보관했다가 지우고, 다른 사람에게는 보이지 않아요.")
                .appFont(15)
                .foregroundStyle(Theme.mutedForeground)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Spacer(minLength: 24)
            VStack(spacing: 16) {
                PrimaryButton(title: "위치 허용하기") {
                    Haptics.tap()
                    onAllow()
                }
                Button("나중에 할게요") { onLater() }
                    .appFont(14, .medium)
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(height: 40)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { pulse = true }
    }
}
