import SwiftUI

/// 정면 캐릭터 (디자인 Character.tsx를 그대로 옮김).
/// - 기본: 상반신 120×132 (프로필 원 안)
/// - peek: 대화 화면 가장자리에서 빼꼼 나오는 모습 (42×46)
/// - fullBody: 꾸미기 미리보기용 전신 120×256
struct CharacterView: View {
    enum Peek { case left, right }

    let avatar: Avatar
    var peek: Peek?
    var fullBody = false

    var body: some View {
        Canvas { ctx, size in
            CharacterPainter.draw(avatar, peek: peek, fullBody: fullBody, in: ctx, size: size)
        }
        .accessibilityHidden(true)
    }

    /// 디자인의 기본 크기
    var naturalSize: CGSize {
        if peek != nil { return CGSize(width: 42, height: 46) }
        return CGSize(width: 120, height: fullBody ? 256 : 132)
    }
}

enum CharacterPainter {
    private typealias P = PoolCharacterPainter
    private static let peekDegrees: Double = 30

    static func draw(_ a: Avatar, peek: CharacterView.Peek?, fullBody: Bool, in base: GraphicsContext, size: CGSize) {
        let vbH: CGFloat = fullBody ? 256 : 132
        let s = min(size.width / 120, size.height / vbH)
        var root = base
        root.translateBy(x: (size.width - 120 * s) / 2, y: (size.height - vbH * s) / 2)
        root.scaleBy(x: s, y: s)

        let skin = AvatarPalette.color(a.skin)
        let hair = AvatarPalette.color(a.hairColor)
        let clothes = AvatarPalette.color(a.clothes)
        let ink = AvatarPalette.ink
        let trim = AvatarPalette.white
        let noseColor = AvatarPalette.mix(a.skin, 0x1B1F29, 0.24)

        var clipped = root
        if let peek {
            clipped.clip(to: Path(CGRect(x: peek == .right ? 49 : -60, y: -20, width: 131, height: 180)))
        }
        var ctx = clipped
        if let peek {
            ctx.translateBy(x: 60, y: 110)
            ctx.rotate(by: .degrees(peek == .right ? peekDegrees : -peekDegrees))
            ctx.translateBy(x: -60, y: -110)
        }

        if fullBody {
            var f = ctx
            f.translateBy(x: 0, y: 96)
            f.scaleBy(x: 1, y: 0.62)
            PoolFloatPainter.draw(a, layer: .back, in: f)
            var limbs = ctx
            limbs.translateBy(x: 0, y: -23.5)
            limbs.scaleBy(x: 1, y: 1.25)
            P.fill(limbs, "M34 136L34 202Q28 204 29 211Q31 217 47 214L51 141ZM69 141L73 214Q89 217 91 211Q92 204 86 202L86 136Z", skin)
            P.fill(limbs, "M31 94Q18 97 17 115L13 150Q14 159 21 154L30 120L40 105M89 94Q102 97 103 115L107 150Q106 159 99 154L90 120L80 105", skin)
            P.fill(limbs, "M31 101Q60 90 89 101L89 146Q74 156 60 148Q46 156 31 146Z", a.outfit == "shorts" ? skin : clothes)
        }
        if a.hair == "bun" { P.fill(ctx, "M51 26C37 22 39 6 52 4C69 0 77 17 65 27Z", hair) }
        if a.hair == "bob" { P.fill(ctx, "M25 52C16 34 28 8 50 12C77 2 97 24 95 49L100 68Q113 82 97 91L91 104Q69 111 29 98Q13 92 24 78Q12 66 25 52Z", hair) }
        if !fullBody {
            let d: String
            if peek != nil {
                switch a.body {
                case "slim": d = "M39 91Q60 81 81 91Q88 111 54 136L-40 210H-100L16 125Q28 105 39 91Z"
                case "broad": d = "M24 97Q60 78 96 97Q108 113 54 136L-40 210H-110L0 132Q12 108 24 97Z"
                default: d = "M30 97Q60 80 90 97Q103 113 54 136L-40 210H-100L6 130Q17 109 30 97Z"
                }
            } else {
                switch a.body {
                case "slim": d = "M39 91Q60 81 81 91L88 128H32Z"
                case "broad": d = "M24 97Q60 78 96 97L106 128H14Z"
                default: d = "M30 97Q60 80 90 97Q103 109 98 128H22Q17 109 30 97Z"
                }
            }
            var bodyCtx = ctx
            if peek == .left {
                bodyCtx.translateBy(x: 120, y: 0)
                bodyCtx.scaleBy(x: -1, y: 1)
            }
            P.fill(bodyCtx, d, a.outfit == "shorts" ? skin : clothes)
        }
        P.fill(ctx, "M49 79V96Q60 104 71 96V79", skin)
        if a.outfit == "rashguard" { P.fill(ctx, "M48 91Q60 102 72 91Q60 109 48 91Z", trim) }
        if a.outfit == "onepiece" { P.stroke(ctx, "M46 93Q60 106 74 93", trim, 3) }
        if a.outfit == "shorts" && fullBody {
            var shorts = ctx
            shorts.translateBy(x: 0, y: -23.5)
            shorts.scaleBy(x: 1, y: 1.25)
            P.fill(shorts, "M31 127H89V153L64 156L60 142L56 156L31 153Z", clothes)
        }
        if fullBody {
            var f = ctx
            f.translateBy(x: 0, y: 96)
            f.scaleBy(x: 1, y: 0.62)
            PoolFloatPainter.draw(a, layer: .front, in: f)
            if a.float != "none" {
                ctx.fill(Path(ellipseIn: CGRect(x: 14, y: 145, width: 14, height: 20)), with: .color(skin))
                ctx.fill(Path(ellipseIn: CGRect(x: 92, y: 145, width: 14, height: 20)), with: .color(skin))
            }
        }
        ctx.fill(Path(ellipseIn: CGRect(x: 19, y: 51, width: 16, height: 20)), with: .color(skin))
        ctx.fill(Path(ellipseIn: CGRect(x: 85, y: 51, width: 16, height: 20)), with: .color(skin))
        P.fill(ctx, "M27 45C27 26 42 20 60 20C78 20 93 26 93 45V65C93 82 78 95 60 95C42 95 27 82 27 65Z", skin)
        switch a.hair {
        case "short": P.fill(ctx, "M27 48C12 36 18 22 30 24C24 9 38 7 45 15C46 0 62 2 65 13C76 0 89 13 85 24C104 19 108 39 92 44L83 47L82 30Q52 42 34 32Z", hair)
        case "bob": P.fill(ctx, "M24 54C15 31 32 13 52 15C78 8 99 27 92 46C90 55 79 53 73 44L64 27Q56 46 31 51L30 70Z", hair)
        case "curly": P.fill(ctx, "M26 48C9 45 11 28 23 27C13 15 30 5 39 14C37 0 53 1 57 12C63 -2 78 4 77 17C92 5 106 22 94 31C110 36 99 53 85 47L80 35Q55 46 30 37Z", hair)
        case "bun": P.fill(ctx, "M28 47Q22 19 54 19Q84 17 91 45L82 42L77 30Q61 24 38 40Z", hair)
        default: break
        }
        P.stroke(ctx, "M38 48Q44 44 50 48M70 48Q76 44 82 48", ink, 3)
        switch a.eyes {
        case "dot":
            ctx.fill(Path(ellipseIn: CGRect(x: 41, y: 55, width: 6, height: 6)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 73, y: 55, width: 6, height: 6)), with: .color(ink))
        case "oval":
            ctx.fill(Path(ellipseIn: CGRect(x: 41, y: 53, width: 6, height: 10)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 73, y: 53, width: 6, height: 10)), with: .color(ink))
        case "happy": P.stroke(ctx, "M39 59Q44 50 49 59M71 59Q76 50 81 59", ink, 3)
        case "sleepy": P.stroke(ctx, "M39 57H49M71 57H81", ink, 3)
        default: break
        }
        switch a.nose {
        case "button": P.stroke(ctx, "M57 65Q55 71 60 71Q65 71 63 65", noseColor, 3)
        case "round": ctx.fill(Path(ellipseIn: CGRect(x: 55, y: 63, width: 10, height: 8)), with: .color(noseColor))
        case "triangle": P.fill(ctx, "M60 60L55 70H65Z", noseColor)
        default: break
        }
        switch a.mouth {
        case "smile": P.stroke(ctx, "M50 78Q60 87 70 78", ink, 3)
        case "grin":
            P.fill(ctx, "M49 75H71Q69 88 60 88Q51 88 49 75", ink)
            P.fill(ctx, "M51 76H69V80H51Z", trim)
        case "small": P.stroke(ctx, "M55 79H65", ink, 3)
        case "surprised": ctx.fill(Path(ellipseIn: CGRect(x: 56, y: 74, width: 8, height: 10)), with: .color(ink))
        default: break
        }
        if a.eyewear != "snorkel" && a.eyewear != "none" {
            var lenses = Path()
            if a.eyewear == "round" {
                lenses.addEllipse(in: CGRect(x: 33, y: 46, width: 22, height: 22))
                lenses.addEllipse(in: CGRect(x: 65, y: 46, width: 22, height: 22))
            } else {
                lenses.addRoundedRect(in: CGRect(x: 32, y: 49, width: 24, height: 18), cornerSize: CGSize(width: 5, height: 5))
                lenses.addRoundedRect(in: CGRect(x: 64, y: 49, width: 24, height: 18), cornerSize: CGSize(width: 5, height: 5))
            }
            if a.eyewear == "sun" { ctx.fill(lenses, with: .color(ink)) }
            ctx.stroke(lenses, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            P.stroke(ctx, "M55 57H65M28 55H32M88 55H92", ink, 3)
        }
        if a.eyewear == "snorkel" {
            let blue = AvatarPalette.color("blue")
            let mask = Path(roundedRect: CGRect(x: 29, y: 47, width: 62, height: 25), cornerRadius: 10)
            ctx.fill(mask, with: .color(AvatarPalette.mask.opacity(0.18)))
            ctx.stroke(mask, with: .color(blue), lineWidth: 5)
            P.stroke(ctx, "M60 49V69", blue, 3, cap: .butt)
            P.stroke(ctx, "M36 51L44 49M74 50L81 49", AvatarPalette.white, 2)
            P.stroke(ctx, "M72 77H94Q102 77 102 67V27", blue, 7, cap: .butt)
            ctx.fill(Path(roundedRect: CGRect(x: 98, y: 19, width: 8, height: 14), cornerRadius: 3), with: .color(AvatarPalette.color("lemon")))
        }
        if peek == nil {
            var propCtx = ctx
            if fullBody {
                propCtx.translateBy(x: 103, y: 160)
                propCtx.scaleBy(x: 0.8, y: 0.8)
            } else {
                propCtx.translateBy(x: 99, y: 112)
                propCtx.scaleBy(x: 0.65, y: 0.65)
            }
            PoolPropPainter.draw(a.prop, in: propCtx)
        }

        // 빼꼼: 화면 모서리를 잡은 소매와 손 (회전하지 않은 좌표)
        if let peek {
            var arms = clipped
            if peek == .left {
                arms.translateBy(x: 120, y: 0)
                arms.scaleBy(x: -1, y: 1)
            }
            P.fill(arms, "M82 103Q98 105 102 119Q104 132 63 145L51 134Q85 121 81 115L72 112", clothes)
            P.fill(arms, "M44 134L51 133Q59 130 62 134Q63 138 57 139Q65 137 65 142Q65 145 59 145Q65 145 64 149Q63 152 57 152Q62 152 61 155Q58 159 50 156L44 151Z", skin)
            P.fill(arms, "M44 80L51 79Q59 76 62 80Q63 84 57 85Q65 83 65 88Q65 91 59 91Q65 91 64 95Q63 98 57 98Q62 98 61 101Q58 105 50 102L44 97Z", skin)
        }
    }
}
