import AuthenticationServices
import CryptoKit
import KakaoSDKAuth
import KakaoSDKCommon
import KakaoSDKUser
import SwiftUI

struct LoginView: View {
    enum Provider { case kakao, apple, dev }

    @Environment(AppState.self) private var app
    @State private var busy: Provider?
    @State private var done: Provider?
    @State private var error: String?
    @State private var shakes = 0
    @State private var rawNonce = ""
    @State private var devName = ""

    private var locked: Bool { busy != nil || done != nil }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content
                    .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.background)
        .animation(Motion.settle(), value: error)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                RippleHero(markSize: 92, spread: 250)
                    .frame(height: 170)
                VStack(spacing: 8) {
                    Text("같은 공간 채팅")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.foreground)
                        .riseIn(0.15)
                    Text("지금 여기, 같은 경험")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.mutedForeground)
                        .riseIn(0.22)
                }
            }
            Spacer(minLength: 32)

            VStack(spacing: 10) {
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .padding(.bottom, 4)
                }

                kakaoButton.riseIn(0.3)
                appleButton.riseIn(0.36)

                #if DEBUG
                devLogin.riseIn(0.42)
                #endif
            }
            .shake(shakes)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: 버튼

    private var kakaoButton: some View {
        Button(action: kakaoLogin) {
            HStack(spacing: 8) {
                providerMark(.kakao, tint: Theme.kakaoLabel) {
                    KakaoSymbol().fill(Theme.kakaoLabel).frame(width: 21, height: 20)
                }
                Text("카카오로 시작하기")
                    .font(.system(size: 18, weight: .medium))
            }
            .foregroundStyle(Theme.kakaoLabel)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.controlHeight)
            .background(Theme.kakao)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(PressStyle(dim: 0.7))
        .modifier(ProviderState(dimmed: isDimmed(.kakao)))
        .disabled(locked)
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            Haptics.tap()
            rawNonce = Self.randomNonce()
            request.requestedScopes = []
            request.nonce = Self.sha256(rawNonce)
            withAnimation(Motion.settle()) { busy = .apple; error = nil }
        } onCompletion: { result in
            appleCompletion(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: Theme.controlHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            if busy == .apple || done == .apple {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(Color.black)
                    .overlay { providerMark(.apple, tint: .white) { EmptyView() } }
                    .transition(.opacity)
            }
        }
        .modifier(ProviderState(dimmed: isDimmed(.apple)))
        .disabled(locked)
    }

    #if DEBUG
    private var devLogin: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("개발 빌드").font(.caption2).foregroundStyle(Theme.mutedForeground)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .padding(.top, 10)
            HStack(spacing: 8) {
                TextField("개발용 이름", text: $devName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .shadField()
                ShadButton(title: done == .dev ? "완료" : "개발 로그인", variant: .outline, isLoading: busy == .dev, compact: true) {
                    Haptics.tap()
                    Task { await send(.dev, "/auth/dev", body: ["name": devName]) }
                }
                .disabled(devName.isEmpty || locked)
            }
        }
        .modifier(ProviderState(dimmed: isDimmed(.dev)))
    }
    #endif

    /// 진행 중이면 스피너, 끝나면 체크, 평소엔 브랜드 심볼
    @ViewBuilder
    private func providerMark<Mark: View>(_ provider: Provider, tint: Color, @ViewBuilder mark: () -> Mark) -> some View {
        ZStack {
            if busy == provider {
                ProgressView().tint(tint).transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if done == provider {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                mark().transition(.opacity)
            }
        }
        .animation(Motion.pop, value: busy)
        .animation(Motion.pop, value: done)
    }

    private func isDimmed(_ provider: Provider) -> Bool {
        guard let active = busy ?? done else { return false }
        return active != provider
    }

    // MARK: 로그인

    private func kakaoLogin() {
        Haptics.tap()
        withAnimation(Motion.settle()) { busy = .kakao; error = nil }
        let handler: (OAuthToken?, Error?) -> Void = { token, err in
            if let token {
                Task { await send(.kakao, "/auth/kakao", body: ["access_token": token.accessToken]) }
            } else {
                fail(Self.isCancel(err) ? nil : "카카오 로그인에 실패했어요. 다시 시도해 주세요.")
            }
        }
        if UserApi.isKakaoTalkLoginAvailable() {
            UserApi.shared.loginWithKakaoTalk(completion: handler)
        } else {
            UserApi.shared.loginWithKakaoAccount(completion: handler)
        }
    }

    private func appleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                fail("Apple 로그인 정보를 읽지 못했어요.")
                return
            }
            var body = ["identity_token": token, "raw_nonce": rawNonce]
            if let code = cred.authorizationCode, let s = String(data: code, encoding: .utf8) {
                body["authorization_code"] = s
            }
            Task { await send(.apple, "/auth/apple", body: body) }
        case .failure(let err):
            let canceled = (err as? ASAuthorizationError)?.code == .canceled
            fail(canceled ? nil : "Apple 로그인에 실패했어요. 다시 시도해 주세요.")
        }
    }

    private func send(_ provider: Provider, _ path: String, body: [String: String]) async {
        withAnimation(Motion.settle()) { busy = provider; error = nil }
        do {
            let token: TokenOut = try await app.api.request("POST", path, body: body, auth: false)
            Haptics.success()
            withAnimation(Motion.settle()) { busy = nil; done = provider }
            try? await Task.sleep(for: .milliseconds(450))
            await app.applyLogin(token)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// message가 nil이면 사용자가 취소한 것 — 조용히 원래 상태로
    private func fail(_ message: String?) {
        withAnimation(Motion.settle()) { busy = nil }
        guard let message else { return }
        Haptics.error()
        withAnimation(Motion.settle()) { error = message }
        withAnimation(.linear(duration: 0.4)) { shakes += 1 }
    }

    private static func isCancel(_ err: Error?) -> Bool {
        guard let sdk = err as? SdkError, case .ClientFailed(let reason, _) = sdk else { return false }
        return reason == .Cancelled
    }

    static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 다른 로그인 수단이 진행 중이면 흐리게
private struct ProviderState: ViewModifier {
    let dimmed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.4 : 1)
            .animation(Motion.settle(), value: dimmed)
    }
}
