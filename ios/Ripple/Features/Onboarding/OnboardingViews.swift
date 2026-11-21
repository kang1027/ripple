import PhotosUI
import SwiftUI

struct PhoneVerifyView: View {
    @Environment(AppState.self) private var app
    @State private var phone = ""
    @State private var code = ""
    @State private var sent = false
    @State private var remaining = 0
    @State private var resendWait = 0
    @State private var sending = false
    @State private var verifying = false
    @State private var verified = false
    @State private var error: String?
    @State private var shakes = 0
    @FocusState private var phoneFocused: Bool
    @FocusState private var codeFocused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var digits: String { phone.filter(\.isNumber) }
    /// 010은 11자리, 011·016 같은 옛 번호는 10~11자리
    private var phoneValid: Bool {
        guard digits.hasPrefix("01") else { return false }
        return digits.hasPrefix("010") ? digits.count == 11 : (10...11).contains(digits.count)
    }
    private var expired: Bool { sent && remaining == 0 }

    var body: some View {
        FormScaffold(scrollTarget: $scrollTarget) {
            OnboardingHeader(step: 1, total: 2) {
                phoneFocused = false
                codeFocused = false
                Task { await app.leaveOnboarding() }
            }
        } content: {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("휴대폰 번호를")
                        Text("인증해 주세요")
                    }
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.foreground)
                    Text("번호 하나에 계정 하나만 만들 수 있어요")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .riseIn(0.05)

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("휴대폰 번호")
                    HStack(spacing: 8) {
                        TextField("010-0000-0000", text: $phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .focused($phoneFocused)
                            .shadField(focused: phoneFocused)
                            .onChange(of: phone) { _, new in
                                let formatted = Self.formatPhone(new)
                                if formatted != new { phone = formatted }
                                if sent && digits != lastSentDigits {
                                    resetCode()
                                }
                            }
                        ShadButton(
                            title: sent ? "다시 받기" : "인증번호 받기",
                            variant: sent ? .outline : .primary,
                            isLoading: sending,
                            compact: true
                        ) {
                            Task { await requestCode() }
                        }
                        .disabled(!phoneValid || resendWait > 0 || verified)
                    }
                    if sent && resendWait > 0 {
                        Text("\(resendWait)초 뒤에 다시 받을 수 있어요")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.mutedForeground)
                            .transition(.opacity)
                    }
                }
                .riseIn(0.12)

                if sent {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            fieldLabel("인증번호 6자리")
                            Spacer()
                            Text(expired ? "만료됨" : "남은 시간 \(String(format: "%d:%02d", remaining / 60, remaining % 60))")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.destructive)
                                .contentTransition(.numericText(countsDown: true))
                        }
                        CodeBoxes(code: $code, focus: $codeFocused, disabled: expired || verifying || verified, done: verified)
                            .shake(shakes)
                        Text(expired ? "인증번호가 만료됐어요. 다시 받아 주세요." : "문자로 받은 인증번호를 입력해 주세요")
                            .font(.footnote)
                            .foregroundStyle(expired ? Theme.destructive : Theme.mutedForeground)
                    }
                    .id("code")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -12)),
                        removal: .opacity
                    ))
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .id("error")
                        .font(.footnote)
                        .foregroundStyle(Theme.destructive)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
        } footer: {
            ShadButton(title: verified ? "인증 완료" : "확인", isLoading: verifying) {
                Task { await verify() }
            }
            .disabled(code.count != 6 || expired || verified)
        }
        .animation(Motion.settle(0.35), value: sent)
        .animation(Motion.settle(), value: error)
        .animation(Motion.settle(), value: resendWait > 0)
        .onReceive(timer) { _ in
            if remaining > 0 { withAnimation { remaining -= 1 } }
            if resendWait > 0 { resendWait -= 1 }
        }
        .onChange(of: expired) { _, isExpired in
            if isExpired { code = "" }
        }
        .onChange(of: code) { _, new in
            if new.count == 6 && !verifying && !verified { Task { await verify() } }
        }
        .onChange(of: codeFocused) { _, focused in
            if focused { scrollTarget = "code" }
        }
        .onAppear { phoneFocused = true }
    }

    @State private var lastSentDigits = ""
    @State private var scrollTarget: String?

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.mutedForeground)
    }

    private func resetCode() {
        sent = false
        code = ""
        remaining = 0
        resendWait = 0
    }

    private func requestCode() async {
        Haptics.tap()
        sending = true
        defer { sending = false }
        error = nil
        do {
            let _: OkResponse = try await app.api.request("POST", "/auth/phone/request", body: ["phone": digits])
            lastSentDigits = digits
            code = ""
            remaining = 180
            resendWait = 60
            sent = true
            // 코드 칸이 화면에 생긴 다음 프레임에 포커스를 옮겨야 키보드가 끊기지 않음
            try? await Task.sleep(for: .milliseconds(60))
            codeFocused = true
            scrollTarget = "code"
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            scrollTarget = "error"
        }
    }

    private func verify() async {
        guard code.count == 6, !verifying else { return }
        verifying = true
        error = nil
        do {
            let _: OkResponse = try await app.api.request(
                "POST", "/auth/phone/verify", body: ["phone": digits, "code": code]
            )
            Haptics.success()
            verifying = false
            verified = true
            codeFocused = false
            try? await Task.sleep(for: .milliseconds(550))
            await app.refreshMe()
        } catch {
            verifying = false
            Haptics.error()
            self.error = error.localizedDescription
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            code = ""
            codeFocused = true
            scrollTarget = "error"
        }
    }

    /// 010-1234-5678 형태로 입력 중에 하이픈을 넣음
    static func formatPhone(_ raw: String) -> String {
        let d = String(raw.filter(\.isNumber).prefix(11))
        if d.count <= 3 { return d }
        if d.count <= 7 { return "\(d.prefix(3))-\(d.dropFirst(3))" }
        return "\(d.prefix(3))-\(d.dropFirst(3).prefix(4))-\(d.dropFirst(7))"
    }
}

/// 6칸 인증번호 입력. 실제 입력은 숨긴 TextField가 받고 칸은 보여주기만 함
struct CodeBoxes: View {
    @Binding var code: String
    var focus: FocusState<Bool>.Binding
    var disabled = false
    var done = false

    private let length = 6

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(focus)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .accessibilityLabel("인증번호")
                .onChange(of: code) { old, new in
                    let cleaned = String(new.filter(\.isNumber).prefix(length))
                    if cleaned != new { code = cleaned }
                    if cleaned.count > old.count { Haptics.select() }
                }

            HStack(spacing: 8) {
                ForEach(0..<length, id: \.self) { i in box(i) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !disabled { focus.wrappedValue = true } }
        }
        .disabled(disabled)
    }

    private func box(_ i: Int) -> some View {
        let chars = Array(code)
        let digit = i < chars.count ? String(chars[i]) : nil
        let active = focus.wrappedValue && !disabled && i == min(code.count, length - 1)

        return ZStack {
            RoundedRectangle(cornerRadius: Theme.radius)
                .fill(disabled && !done ? Theme.muted : Theme.background)
            if let digit {
                Text(digit)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.foreground)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if active {
                Caret()
            }
        }
        .frame(height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(done ? Theme.foreground : active ? Theme.foreground : Theme.border, lineWidth: active || done ? 1.5 : 1)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.radius + 3)
                .stroke(active ? Theme.muted : .clear, lineWidth: 6)
                .padding(-1.5)
        )
        .scaleEffect(done ? 1.04 : 1)
        .animation(Motion.pop.delay(Double(i) * 0.04), value: done)
        .animation(Motion.pop, value: digit)
        .animation(Motion.settle(), value: active)
    }
}

private struct Caret: View {
    var body: some View {
        PhaseAnimator([1.0, 0.0]) { phase in
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.foreground)
                .frame(width: 2, height: 24)
                .opacity(phase)
        } animation: { _ in .easeInOut(duration: 0.5) }
    }
}

struct ProfileSetupView: View {
    @Environment(AppState.self) private var app
    @State private var nickname = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageVersion = 0
    @State private var loading = false
    @State private var error: String?
    @State private var shakes = 0
    @FocusState private var nicknameFocused: Bool
    @State private var scrollTarget: String?
    @State private var avatar = AvatarStore.load()
    @State private var editingCharacter = false
    var isEditing = false

    private let maxLength = 12

    init(isEditing: Bool = false) {
        self.isEditing = isEditing
    }

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        FormScaffold(scrollTarget: $scrollTarget) {
            if !isEditing {
                OnboardingHeader(step: 2, total: 2)
            }
        } content: {
            VStack(alignment: .leading, spacing: 28) {
                if !isEditing {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("여기서 쓸 이름과")
                            Text("캐릭터를 정해요")
                        }
                        .appFont(28, .heavy)
                        .foregroundStyle(Theme.foreground)
                        Text("주변 사람들에게 보이는 모습이에요")
                            .appFont(14)
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    .riseIn(0.05)
                }

                avatarPicker
                    .frame(maxWidth: .infinity)
                    .riseIn(0.12)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("닉네임").appFont(12, .semibold).foregroundStyle(Theme.mutedForeground)
                        Spacer()
                        Button {
                            Haptics.select()
                            nickname = String(NicknameRule.random(excluding: nickname).prefix(maxLength))
                        } label: {
                            Label("랜덤", systemImage: "shuffle").appFont(12, .semibold).foregroundStyle(Theme.primary)
                        }
                    }
                    TextField("2~12자", text: $nickname)
                        .focused($nicknameFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .padding(.trailing, 44)
                        .shadField(focused: nicknameFocused, invalid: error != nil)
                        .overlay(alignment: .trailing) {
                            Text("\(nickname.count)/\(maxLength)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.mutedForeground)
                                .contentTransition(.numericText())
                                .padding(.trailing, 14)
                        }
                        .shake(shakes)
                        .onChange(of: nickname) { _, new in
                            if new.count > maxLength { nickname = String(new.prefix(maxLength)) }
                            if error != nil { withAnimation(Motion.settle()) { error = nil } }
                        }
                    Group {
                        if let error {
                            Text(error).foregroundStyle(Theme.destructive)
                        } else {
                            Text("다른 사람과 겹치지 않아야 해요").foregroundStyle(Theme.mutedForeground)
                        }
                    }
                    .font(.footnote)
                    .transition(.opacity)
                }
                .id("nickname")
                .riseIn(0.18)
            }
            .padding(.horizontal, 20)
            .padding(.top, isEditing ? 20 : 28)
        } footer: {
            ShadButton(title: isEditing ? "저장" : "시작하기", isLoading: loading) { Task { await save() } }
                .disabled(trimmed.count < 2)
        }
        .animation(Motion.settle(), value: error)
        .onAppear { nickname = app.me?.nickname ?? "" }
        .onChange(of: nicknameFocused) { _, focused in
            if focused { scrollTarget = "nickname" }
        }
        .onChange(of: pickerItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let picked = UIImage(data: data) {
                    Haptics.tap()
                    withAnimation(Motion.settle()) { image = picked }
                    imageVersion += 1
                }
            }
        }
    }

    private var avatarPicker: some View {
        Button {
            Haptics.tap()
            editingCharacter = true
        } label: {
            VStack(spacing: 12) {
                CharacterView(avatar: avatar)
                    .frame(width: 132, height: 145)
                    .offset(y: 12)
                    .frame(width: 160, height: 160)
                    .background(Circle().fill(Theme.primarySoft))
                    .clipShape(Circle())
                Text("캐릭터 꾸미기")
                    .appFont(12, .bold)
                    .foregroundStyle(Theme.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.secondary))
            }
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .accessibilityLabel("캐릭터 꾸미기")
        .sheet(isPresented: $editingCharacter) {
            CharacterEditorSheet(initial: avatar, saveTitle: "이 모습으로 정하기") { next in
                avatar = next
                AvatarStore.save(next)
                return nil
            }
        }
    }

    private var photoPicker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 112, height: 112)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                        .transition(.opacity)
                } else {
                    ShadAvatar(url: app.me?.avatarUrl, size: 112)
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: imageVersion) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.9, duration: 0.11)
                    SpringKeyframe(1.06, duration: 0.2)
                    SpringKeyframe(1.0, duration: 0.22)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryForeground)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.primary))
                    .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                    .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .accessibilityLabel("프로필 사진 선택")
    }

    private func save() async {
        nicknameFocused = false
        loading = true
        defer { loading = false }
        error = nil
        do {
            if let image, let jpeg = image.jpegData(compressionQuality: 0.8) {
                let _: UserOut = try await app.api.uploadImage("/me/avatar", jpeg: jpeg)
            }
            struct Body: Encodable { let nickname: String; let avatar: Avatar }
            AvatarStore.save(avatar)
            let _: UserOut = try await app.api.request("PATCH", "/me", body: Body(nickname: trimmed, avatar: avatar))
            Haptics.success()
            await app.refreshMe()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        }
    }
}
