import SwiftUI

/// 나만의 캐릭터 꾸미기 (디자인 CharacterEditor.tsx). 저장하면 기기와 서버에 같이 남긴다
struct CharacterEditorSheet: View {
    let initial: Avatar
    var saveTitle = "이 모습으로 대화하기"
    let onSave: (Avatar) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Avatar
    @State private var part: Part = .float
    @State private var view: PreviewMode = .full
    @State private var saving = false
    @State private var error: String?

    init(initial: Avatar, saveTitle: String = "이 모습으로 대화하기", onSave: @escaping (Avatar) async -> String?) {
        self.initial = initial
        self.saveTitle = saveTitle
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    enum PreviewMode { case full, top }

    enum Part: String, CaseIterable, Identifiable {
        case float, floatColor, eyewear, outfit, clothes, prop, hair, hairColor, skin, eyes, nose, mouth, body
        var id: String { rawValue }

        var label: String {
            switch self {
            case .float: return "튜브"
            case .floatColor: return "튜브 색"
            case .eyewear: return "아이웨어"
            case .outfit: return "수영복"
            case .clothes: return "수영복 색"
            case .prop: return "소품"
            case .hair: return "머리"
            case .hairColor: return "머리색"
            case .skin: return "피부"
            case .eyes: return "눈"
            case .nose: return "코"
            case .mouth: return "입"
            case .body: return "몸"
            }
        }

        var options: [String] {
            switch self {
            case .float: return Avatar.Options.float
            case .floatColor: return Avatar.Options.floatColor
            case .eyewear: return Avatar.Options.eyewear
            case .outfit: return Avatar.Options.outfit
            case .clothes: return Avatar.Options.clothes
            case .prop: return Avatar.Options.prop
            case .hair: return Avatar.Options.hair
            case .hairColor: return Avatar.Options.hairColor
            case .skin: return Avatar.Options.skin
            case .eyes: return Avatar.Options.eyes
            case .nose: return Avatar.Options.nose
            case .mouth: return Avatar.Options.mouth
            case .body: return Avatar.Options.body
            }
        }

        var isColor: Bool { self == .hairColor || self == .skin || self == .clothes || self == .floatColor }

        var keyPath: WritableKeyPath<Avatar, String> {
            switch self {
            case .float: return \.float
            case .floatColor: return \.floatColor
            case .eyewear: return \.eyewear
            case .outfit: return \.outfit
            case .clothes: return \.clothes
            case .prop: return \.prop
            case .hair: return \.hair
            case .hairColor: return \.hairColor
            case .skin: return \.skin
            case .eyes: return \.eyes
            case .nose: return \.nose
            case .mouth: return \.mouth
            case .body: return \.body
            }
        }
    }

    static let labels: [String: String] = [
        "short": "짧은 머리", "bob": "단발", "curly": "곱슬", "bun": "올림머리", "none": "없음", "ink": "차콜", "cocoa": "초코",
        "gold": "금빛", "blue": "파랑", "rose": "분홍", "porcelain": "밝은 피부", "peach": "복숭아 피부", "warm": "따뜻한 피부",
        "tan": "구릿빛 피부", "deep": "짙은 피부", "espresso": "깊은 피부", "round": "동그란 안경", "square": "네모 안경",
        "sun": "선글라스", "dot": "점눈", "oval": "동그란 눈", "happy": "웃는 눈", "sleepy": "느긋한 눈", "button": "작은 코",
        "triangle": "세모 코", "smile": "미소", "grin": "활짝", "small": "작은 입", "surprised": "놀란 입", "slim": "슬림",
        "broad": "든든", "rashguard": "래시가드", "onepiece": "원피스 수영복", "shorts": "수영 반바지", "mint": "민트",
        "lemon": "노랑", "ring": "기본 튜브", "flamingo": "플라밍고", "dolphin": "돌고래", "snorkel": "스노클",
        "cocktail": "칵테일", "juice": "주스", "watergun": "물총", "coral": "코랄", "lilac": "라일락", "aqua": "아쿠아",
        "tangerine": "귤색", "cherry": "체리", "lime": "라임", "lavender": "라벤더", "ice": "아이스",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "나만의 캐릭터") { dismiss() }
                preview.padding(.top, 12)
                partTabs.padding(.top, 20)
                options.padding(.top, 16)
                if let error {
                    Text(error).appFont(12).foregroundStyle(Theme.destructive).padding(.top, 12)
                }
                ShadButton(title: saveTitle, isLoading: saving, systemImage: "checkmark") {
                    Task {
                        saving = true
                        error = await onSave(draft)
                        saving = false
                        if error == nil {
                            Haptics.success()
                            dismiss()
                        }
                    }
                }
                .padding(.top, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .rippleSheet(detents: [.large])
    }

    private var preview: some View {
        ZStack {
            PoolFloorPreview()
            Group {
                if view == .full {
                    CharacterView(avatar: draft, fullBody: true).frame(width: 108, height: 182)
                } else {
                    PoolCharacterView(avatar: draft).scaleEffect(2.8).frame(width: 112, height: 145)
                }
            }
            .animation(Motion.settle(), value: draft)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.select()
                withAnimation(Motion.settle()) { draft = .default }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.foreground)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.background.opacity(0.8)))
            }
            .padding(8)
            .accessibilityLabel("캐릭터 초기화")
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                ForEach([(PreviewMode.full, "전신"), (.top, "탑뷰")], id: \.1) { mode, label in
                    Button {
                        Haptics.select()
                        view = mode
                    } label: {
                        Text(label)
                            .appFont(12, view == mode ? .semibold : .regular)
                            .foregroundStyle(Theme.foreground)
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(view == mode ? Theme.secondary : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.background))
            .padding(8)
        }
    }

    private var partTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Part.allCases) { p in
                    Button {
                        Haptics.select()
                        part = p
                    } label: {
                        Text(p.label)
                            .appFont(12, part == p ? .bold : .regular)
                            .foregroundStyle(part == p ? Theme.primary : Theme.mutedForeground)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(part == p ? Theme.primarySoft : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var options: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(part.options, id: \.self) { value in
                let selected = draft[keyPath: part.keyPath] == value
                var candidate: Avatar { var c = draft; c[keyPath: part.keyPath] = value; return c }
                Button {
                    Haptics.select()
                    withAnimation(Motion.settle()) { draft[keyPath: part.keyPath] = value }
                } label: {
                    VStack(spacing: 4) {
                        if part.isColor {
                            Circle()
                                .fill(AvatarPalette.color(value))
                                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                                .frame(width: 36, height: 36)
                                .padding(.vertical, 8)
                        } else if part == .float || part == .prop {
                            PoolCharacterView(avatar: candidate).scaleEffect(1.1).frame(width: 54, height: 58)
                        } else {
                            CharacterView(avatar: candidate, fullBody: true).frame(width: 54, height: 58)
                        }
                        Text(Self.labels[value] ?? value).appFont(11, .medium).foregroundStyle(Theme.foreground).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(selected ? Theme.primarySoft : Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(selected ? Theme.primary : Theme.border, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.primary).padding(6)
                        }
                    }
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .accessibilityLabel(Self.labels[value] ?? value)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// 꾸미기 미리보기 바닥: 수영장 타일
struct PoolFloorPreview: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Water.floor))
            var grid = Path()
            var x: CGFloat = 0
            while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += 32 }
            var y: CGFloat = 0
            while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += 32 }
            ctx.stroke(grid, with: .color(Theme.Water.grout), lineWidth: 1)
        }
    }
}

/// 닉네임 규칙 (디자인 identity.ts와 같음)
enum NicknameRule {
    static let banned = ["시발", "씨발", "씨팔", "병신", "개새끼", "좆", "fuck", "shit", "bitch", "운영자", "관리자", "admin", "moderator", "ripple공식"]
    static let adjectives = ["느긋한", "다정한", "유쾌한", "차분한", "명랑한", "용감한", "포근한", "든든한"]
    static let animals = ["곰", "토끼", "고양이", "판다", "수달", "여우", "펭귄", "고래"]
    static let maxLength = 20

    static func validate(_ value: String) -> String? {
        let nickname = value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
        let jamo = (value + nickname).unicodeScalars.contains { s in
            (0x1100...0x11FF).contains(s.value) || (0x3130...0x318F).contains(s.value)
                || (0xA960...0xA97F).contains(s.value) || (0xD7B0...0xD7FF).contains(s.value)
        }
        if jamo { return "초성이나 낱자 대신 완성된 한글을 입력해 주세요" }
        let compact = String(nickname.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
        if compact.range(of: "^[il1]{4,}$", options: .regularExpression) != nil
            || compact.range(of: "[il1]{6,}", options: .regularExpression) != nil
            || compact.range(of: "^[o0]{6,}$", options: .regularExpression) != nil {
            return "구분하기 어려운 바코드 닉네임은 사용할 수 없어요"
        }
        if banned.contains(where: { compact.contains($0) }) { return "사용할 수 없는 표현이 포함되어 있어요" }
        if nickname.isEmpty { return "닉네임을 입력해 주세요" }
        if nickname.range(of: "^[A-Za-z가-힣0-9 ]+$", options: .regularExpression) == nil {
            return "한글, 영어, 숫자와 띄어쓰기를 사용할 수 있어요"
        }
        if nickname.count > maxLength { return "닉네임은 \(maxLength)자 이내로 입력해 주세요" }
        return nil
    }

    static func random(excluding current: String) -> String {
        let all = adjectives.flatMap { a in animals.map { "\(a) \($0)" } }.filter { $0 != current }
        return all.randomElement() ?? "다정한 수달"
    }

    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
    }
}

/// 닉네임 바꾸기 시트
struct NicknameEditorSheet: View {
    let nickname: String
    let onSave: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var touched = false
    @State private var saving = false
    @State private var serverError: String?
    @FocusState private var focused: Bool

    init(nickname: String, onSave: @escaping (String) async -> String?) {
        self.nickname = nickname
        self.onSave = onSave
        _draft = State(initialValue: nickname)
    }

    private var error: String? { NicknameRule.validate(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "닉네임 바꾸기") { dismiss() }
            Text("닉네임").appFont(12, .semibold).foregroundStyle(Theme.mutedForeground).padding(.top, 24).padding(.bottom, 8)
            TextField("", text: $draft)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .shadField(focused: focused, invalid: touched && (error != nil || serverError != nil))
                .onChange(of: draft) { touched = true; serverError = nil }
            Text(feedback)
                .appFont(12)
                .foregroundStyle(touched && (error != nil || serverError != nil) ? Theme.destructive : Theme.mutedForeground)
                .padding(.top, 8)
            ShadButton(title: "랜덤 닉네임", variant: .secondary, systemImage: "shuffle") {
                Haptics.select()
                draft = NicknameRule.random(excluding: draft)
            }
            .padding(.top, 16)
            ShadButton(title: "이 닉네임으로 설정", isLoading: saving, systemImage: "checkmark") {
                touched = true
                guard error == nil else { Haptics.error(); return }
                Task {
                    saving = true
                    serverError = await onSave(NicknameRule.normalized(draft))
                    saving = false
                    if serverError == nil { Haptics.success(); dismiss() } else { Haptics.error() }
                }
            }
            .disabled(error != nil)
            .padding(.top, 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .rippleSheet(detents: [.height(400)])
        .onAppear { focused = true }
    }

    private var feedback: String {
        if touched, let serverError { return serverError }
        if touched, let error { return error }
        return "한글·영어·숫자, 최대 \(NicknameRule.maxLength)자"
    }
}
