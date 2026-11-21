import SwiftUI

/// 수영장 캐릭터 꾸미기 값. 디자인(avatar.ts)의 선택지와 같은 문자열을 쓴다.
/// 서버에 저장될 때도 이 문자열 그대로 보낸다.
struct Avatar: Codable, Hashable {
    var hair: String
    var hairColor: String
    var skin: String
    var eyewear: String
    var eyes: String
    var nose: String
    var mouth: String
    var body: String
    var outfit: String
    var clothes: String
    var float: String
    var floatColor: String
    var prop: String

    enum Options {
        static let hair = ["short", "bob", "curly", "bun", "none"]
        static let hairColor = ["ink", "cocoa", "gold", "blue", "rose"]
        static let skin = ["porcelain", "peach", "warm", "tan", "deep", "espresso"]
        static let eyewear = ["none", "snorkel", "sun", "round", "square"]
        static let eyes = ["dot", "oval", "happy", "sleepy"]
        static let nose = ["button", "round", "triangle"]
        static let mouth = ["smile", "grin", "small", "surprised"]
        static let body = ["round", "slim", "broad"]
        static let outfit = ["rashguard", "onepiece", "shorts"]
        static let clothes = ["blue", "mint", "lemon", "rose", "ink"]
        static let float = ["none", "ring", "flamingo", "dolphin"]
        static let floatColor = ["blue", "mint", "lemon", "rose", "coral", "lilac", "aqua", "tangerine", "cherry", "lime", "lavender", "ice"]
        static let prop = ["none", "cocktail", "juice", "watergun"]
    }

    static let `default` = Avatar(
        hair: "curly", hairColor: "cocoa", skin: "warm", eyewear: "snorkel", eyes: "dot", nose: "button",
        mouth: "smile", body: "round", outfit: "rashguard", clothes: "blue", float: "ring", floatColor: "blue", prop: "none"
    )

    /// 튜브가 있으면 둥둥 떠 있고, 없으면 헤엄친다
    var isFloating: Bool { float != "none" }

    /// 저장된 캐릭터가 없는 사람에게 id로 정해 주는 캐릭터 (디자인의 avatarForNickname과 같은 규칙)
    static func derived(from seedText: String) -> Avatar {
        let seed = seedText.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        var a = Avatar.default
        a.hair = Options.hair[seed % 4]
        a.skin = Options.skin[seed % 6]
        a.hairColor = Options.hairColor[seed % 5]
        a.eyewear = Options.eyewear[seed % 5]
        a.eyes = Options.eyes[seed % 4]
        a.clothes = Options.clothes[seed % 5]
        a.outfit = Options.outfit[seed % 3]
        a.float = Options.float[seed % 4]
        a.floatColor = Options.floatColor[seed % 12]
        a.prop = Options.prop[(seed + 2) % 4]
        return a
    }

    /// 홈 수영장에서 튜브 색이 겹치지 않게 나눠 준다. 내 튜브 색은 빼고 돌린다
    static func distinctPool(ids: [String], ownColor: String) -> [Avatar] {
        let colors = Options.floatColor.filter { $0 != ownColor }
        return ids.enumerated().map { i, id in
            var a = derived(from: id)
            a.floatColor = colors[i % colors.count]
            return a
        }
    }
}

/// 캐릭터 색. 디자인의 --avatar-* oklch 값을 sRGB로 옮긴 값
enum AvatarPalette {
    static let ink = Color(hex: 0x1B1F29)
    static let white = Color(hex: 0xFCFCFC)
    static let mask = Color(hex: 0x8EE3FD)

    static let tones: [String: UInt32] = [
        "ink": 0x1B1F29, "white": 0xFCFCFC, "cocoa": 0x5B351E, "gold": 0xE9AF41, "blue": 0x0C84FA,
        "coral": 0xFB8371, "lilac": 0xC8A2E4, "aqua": 0x6CD7E3, "tangerine": 0xFFA44E, "cherry": 0xE4405E,
        "lime": 0xB5E058, "lavender": 0x8882DB, "ice": 0xD6F0FF, "rose": 0xFA86B6, "mint": 0x43CBA4,
        "lemon": 0xF9D544, "porcelain": 0xFCE7D3, "peach": 0xF9C9A9, "warm": 0xE5AE7E, "tan": 0xC58457,
        "deep": 0x91593C, "espresso": 0x633D2C,
    ]

    static func hex(_ name: String) -> UInt32 { tones[name] ?? 0x0C84FA }
    static func color(_ name: String) -> Color { Color(hex: hex(name)) }

    /// 두 색을 섞는다 (디자인의 color-mix 근사). amount는 b의 비율
    static func mix(_ a: String, _ b: UInt32, _ amount: Double) -> Color {
        mix(hex(a), b, amount)
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> Color {
        func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) / 255 }
        let t = amount
        return Color(
            red: ch(a, 16) * (1 - t) + ch(b, 16) * t,
            green: ch(a, 8) * (1 - t) + ch(b, 8) * t,
            blue: ch(a, 0) * (1 - t) + ch(b, 0) * t
        )
    }
}

/// 내 캐릭터는 서버에 저장 칸이 생기기 전까지 기기에 둔다
enum AvatarStore {
    private static let key = "ripple.avatar.v1"

    static func load() -> Avatar {
        guard let data = UserDefaults.standard.data(forKey: key),
              let avatar = try? JSONDecoder().decode(Avatar.self, from: data) else { return .default }
        return avatar
    }

    static func save(_ avatar: Avatar) {
        if let data = try? JSONEncoder().encode(avatar) { UserDefaults.standard.set(data, forKey: key) }
    }
}
