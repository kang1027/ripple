import KakaoSDKAuth
import KakaoSDKUser
import SwiftUI

/// 내 정보 탭: 캐릭터·닉네임, 화면과 대화, 차단 목록, 문의, 계정
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var blocks: [MemberBrief] = []
    @State private var confirmSignOut = false
    @State private var editingCharacter = false
    @State private var editingNickname = false
    @State private var copied = false

    private var avatar: Avatar { app.me?.avatar ?? AvatarStore.load() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                profile.padding(.top, 16)
                Button {
                    Haptics.tap()
                    editingCharacter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person").font(.system(size: 14, weight: .medium))
                        Text("캐릭터 꾸미기").appFont(14, .semibold)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.foreground)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.xl).fill(Theme.secondary))
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .padding(.top, 16)

                AppearanceControls().padding(.top, 24)

                section("차단한 사용자 \(blocks.count)") {
                    if blocks.isEmpty {
                        VStack(spacing: 0) {
                            Text("🕊️")
                                .font(.system(size: 32))
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Theme.primarySoft))
                            Text("여긴 평화로운 구역").appFont(14, .bold).foregroundStyle(Theme.foreground).padding(.top, 8)
                            Text("차단한 사람이 없어요. 이대로 쭉!").appFont(12).foregroundStyle(Theme.mutedForeground).padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { divider }
                        HStack {
                            Text(b.nickname ?? "알 수 없음").appFont(14, .semibold).foregroundStyle(Theme.foreground)
                            Spacer()
                            Button { Task { await unblock(b.id) } } label: {
                                Text("차단 해제")
                                    .appFont(12, .bold)
                                    .foregroundStyle(Theme.foreground)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Theme.secondary))
                            }
                            .buttonStyle(PressStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .transition(.opacity)
                    }
                }

                section("문의") {
                    Button {
                        UIPasteboard.general.string = "help@ripple.app"
                        Haptics.success()
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        if let url = URL(string: "mailto:help@ripple.app") { UIApplication.shared.open(url) }
                    } label: {
                        HStack {
                            Text("help@ripple.app").appFont(14, .semibold).foregroundStyle(Theme.foreground)
                            Spacer()
                            Text(copied ? "복사했어요" : "")
                                .appFont(12)
                                .foregroundStyle(Theme.mutedForeground)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedForeground)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.99, dim: 0.6))
                }

                section("계정") {
                    Button { confirmSignOut = true } label: {
                        HStack {
                            Text("로그아웃").appFont(14, .semibold).foregroundStyle(Theme.foreground)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.99, dim: 0.6))
                    divider
                    NavigationLink {
                        WithdrawView()
                    } label: {
                        HStack {
                            Text("회원 탈퇴").appFont(14, .semibold).foregroundStyle(Theme.mutedForeground)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedForeground)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.99, dim: 0.6))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .animation(Motion.settle(), value: blocks.map(\.id))
        .task { blocks = (try? await app.api.request("GET", "/blocks")) ?? [] }
        .alert("로그아웃할까요?", isPresented: $confirmSignOut) {
            Button("취소", role: .cancel) {}
            Button("로그아웃", role: .destructive) { app.signOut() }
        }
        .sheet(isPresented: $editingCharacter) {
            CharacterEditorSheet(initial: avatar) { next in await saveAvatar(next) }
        }
        .sheet(isPresented: $editingNickname) {
            NicknameEditorSheet(nickname: app.me?.nickname ?? "") { next in await saveNickname(next) }
        }
    }

    private var profile: some View {
        HStack(spacing: 16) {
            Button {
                Haptics.tap()
                editingCharacter = true
            } label: {
                CharacterView(avatar: avatar)
                    .frame(width: 72, height: 79)
                    .offset(y: 6)
                    .frame(width: 80, height: 80)
                    .background(Circle().fill(Theme.primarySoft))
                    .clipShape(Circle())
            }
            .buttonStyle(PressStyle(scale: 0.95))
            .accessibilityLabel("내 캐릭터 꾸미기")
            VStack(alignment: .leading, spacing: 2) {
                Text("닉네임").appFont(12).foregroundStyle(Theme.mutedForeground)
                Text(app.me?.nickname ?? "").appFont(20, .heavy).foregroundStyle(Theme.foreground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CircleIconButton(systemName: "pencil", label: "닉네임 변경") { editingNickname = true }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).appFont(12, .bold).foregroundStyle(Theme.mutedForeground).padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
        }
        .padding(.top, 28)
    }

    private func saveAvatar(_ next: Avatar) async -> String? {
        struct Body: Encodable { let avatar: Avatar }
        AvatarStore.save(next)
        do {
            let me: UserOut = try await app.api.request("PATCH", "/me", body: Body(avatar: next))
            app.me = me
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func saveNickname(_ next: String) async -> String? {
        struct Body: Encodable { let nickname: String }
        do {
            let me: UserOut = try await app.api.request("PATCH", "/me", body: Body(nickname: next))
            app.me = me
            return nil
        } catch {
            return error.localizedDescription
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
