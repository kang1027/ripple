import KakaoSDKAuth
import KakaoSDKUser
import SwiftUI

/// 마이 탭: 프로필, 차단 목록, 로그아웃, 회원 탈퇴
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var blocks: [MemberBrief] = []
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ProfileSetupView(isEditing: true)
                        .navigationTitle("프로필 수정")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack(spacing: 14) {
                        ShadAvatar(url: app.me?.avatarUrl, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.me?.nickname ?? "")
                                .font(.system(size: 17, weight: .semibold))
                            Text("프로필 수정")
                                .font(.footnote)
                                .foregroundStyle(Theme.mutedForeground)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("차단 목록") {
                if blocks.isEmpty {
                    Text("차단한 사람이 없어요").foregroundStyle(Theme.mutedForeground)
                }
                ForEach(blocks, id: \.id) { b in
                    HStack {
                        ShadAvatar(url: b.avatarUrl, size: 28)
                        Text(b.nickname ?? "알 수 없음")
                        Spacer()
                        Button("해제") { Task { await unblock(b.id) } }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section("계정") {
                Button("로그아웃") { confirmSignOut = true }
                    .foregroundStyle(Theme.foreground)
                NavigationLink {
                    WithdrawView()
                } label: {
                    Text("회원 탈퇴").foregroundStyle(Theme.mutedForeground)
                }
            }
        }
        .task { blocks = (try? await app.api.request("GET", "/blocks")) ?? [] }
        .alert("로그아웃할까요?", isPresented: $confirmSignOut) {
            Button("취소", role: .cancel) {}
            Button("로그아웃", role: .destructive) { app.signOut() }
        }
    }

    private func unblock(_ id: String) async {
        Haptics.tap()
        let _: OkResponse? = try? await app.api.request("DELETE", "/blocks/\(id)")
        withAnimation(Motion.settle()) { blocks.removeAll { $0.id == id } }
    }
}

/// 회원 탈퇴: 무엇이 지워지는지 보여주고 확인 체크 후 탈퇴
struct WithdrawView: View {
    @Environment(AppState.self) private var app
    @State private var agreed = false
    @State private var loading = false
    @State private var error: String?
    @State private var confirm = false

    private let notes = [
        ("person.crop.circle.badge.xmark", "닉네임, 프로필 사진, 로그인 정보가 바로 지워져요"),
        ("bubble.left.and.bubble.right", "들어가 있던 채팅방과 토픽에서 나가요"),
        ("clock", "보낸 메시지는 '알 수 없음'으로 보이다가 24시간 안에 지워져요"),
        ("phone", "같은 번호로 다시 가입할 수 있어요"),
    ]

    var body: some View {
        FormScaffold {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("탈퇴하기 전에")
                        Text("확인해 주세요")
                    }
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.foreground)
                    Text("탈퇴하면 되돌릴 수 없어요")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .riseIn(0.02)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(notes, id: \.1) { icon, text in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.mutedForeground)
                                .frame(width: 22)
                            Text(text)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.muted))
                .riseIn(0.08)

                Button {
                    Haptics.select()
                    withAnimation(Motion.pop) { agreed.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(agreed ? Theme.foreground : Theme.border, lineWidth: 1.5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(agreed ? Theme.foreground : .clear))
                            if agreed {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.primaryForeground)
                                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                            }
                        }
                        .frame(width: 22, height: 22)
                        Text("위 내용을 확인했어요")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.foreground)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98, dim: 1))
                .riseIn(0.14)

                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.destructive)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        } footer: {
            ShadButton(title: "탈퇴하기", variant: .destructive, isLoading: loading) { confirm = true }
                .disabled(!agreed)
        }
        .navigationTitle("회원 탈퇴")
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.settle(), value: error)
        .alert("정말 탈퇴할까요?", isPresented: $confirm) {
            Button("취소", role: .cancel) {}
            Button("탈퇴하기", role: .destructive) { Task { await withdraw() } }
        } message: {
            Text("계정은 바로 지워지고 되돌릴 수 없어요")
        }
    }

    private func withdraw() async {
        loading = true
        error = nil
        do {
            let _: OkResponse = try await app.api.request("DELETE", "/me")
            // 카카오로 가입했으면 앱 연결도 끊음 (실패해도 탈퇴는 이미 끝남)
            if AuthApi.hasToken() { UserApi.shared.unlink { _ in } }
            Haptics.success()
            loading = false
            app.signOut()
        } catch {
            loading = false
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}
