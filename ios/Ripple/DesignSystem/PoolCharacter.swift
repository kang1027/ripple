import SwiftUI

/// 홈 수영장의 탑뷰 캐릭터 (디자인 PoolCharacter.tsx + PoolFloat.tsx + PoolProp.tsx를 그대로 옮김).
/// 기본 크기 32×50pt. time을 넘기면 헤엄치는 팔·다리가 움직인다.
struct PoolCharacterView: View {
    let avatar: Avatar
    var time: Double = 0

    var body: some View {
        Canvas { ctx, size in
            PoolCharacterPainter.draw(avatar, time: time, in: ctx, size: size)
        }
        .frame(width: 32, height: 50)
        .accessibilityHidden(true)
    }
}

enum PoolCharacterPainter {
    static func draw(_ a: Avatar, time: Double, in base: GraphicsContext, size: CGSize) {
        // viewBox -6 -6 132 202, xMidYMid meet
        let s = min(size.width / 132, size.height / 202)
        var ctx = base
        ctx.translateBy(x: (size.width - 132 * s) / 2, y: (size.height - 202 * s) / 2)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 6, y: 6)

        let floating = a.isFloating
        let skin = AvatarPalette.color(a.skin)
        let hair = AvatarPalette.color(a.hairColor)
        let suit = AvatarPalette.color(a.clothes)

        // 튜브 뒤쪽
        var floatCtx = ctx
        floatCtx.translateBy(x: 0, y: 22)
        floatCtx.scaleBy(x: 1, y: 0.85)
        PoolFloatPainter.draw(a, layer: .back, in: floatCtx)

        // 다리·몸통
        var bodyCtx = ctx
        bodyCtx.translateBy(x: 0, y: -12.5)
        bodyCtx.scaleBy(x: 1, y: 1.25)
        if floating {
            fill(bodyCtx, "M43 90L38 137Q32 140 34 146Q40 152 47 140L58 94Z", skin)
            fill(bodyCtx, "M62 94L73 140Q80 152 86 146Q88 140 82 137L77 90Z", skin)
        } else {
            fill(rotated(bodyCtx, swing(time, period: 1, delay: 0), at: CGPoint(x: 51, y: 88)),
                 "M47 87L40 131Q34 135 37 141Q43 146 49 133L58 91Z", skin)
            fill(rotated(bodyCtx, swing(time, period: 1, delay: -0.5), at: CGPoint(x: 69, y: 88)),
                 "M62 91L71 133Q77 146 83 141Q86 135 80 131L73 87Z", skin)
        }
        fill(bodyCtx, "M40 51Q60 43 80 51L80 92Q60 108 40 92Z", a.outfit == "shorts" ? skin : suit)
        if a.outfit == "shorts" {
            fill(bodyCtx, "M40 79H80L78 99H65L60 91L55 99H42Z", suit)
        } else {
            stroke(bodyCtx, "M44 62Q60 67 76 62", AvatarPalette.white, 4, cap: .butt)
        }

        // 튜브 앞쪽
        PoolFloatPainter.draw(a, layer: .front, in: floatCtx)

        // 팔·소품
        if floating {
            fill(bodyCtx, "M43 55Q28 48 21 63L13 83Q13 92 20 88L31 70L48 64Z", skin)
            fill(bodyCtx, "M77 55Q92 48 99 63L107 83Q107 92 100 88L89 70L72 64Z", skin)
            var propCtx = bodyCtx
            propCtx.translateBy(x: 103, y: 83)
            propCtx.scaleBy(x: 0.7, y: 0.7)
            PoolPropPainter.draw(a.prop, in: propCtx)
        } else {
            let left = rotated(bodyCtx, swing(time, period: 1.9, delay: 0), at: CGPoint(x: 43, y: 53))
            fill(left, "M43 53Q31 43 29 27L26 15Q22 8 19 14L20 30Q22 52 37 64Z", skin)
            let rightAngle = a.prop == "none" ? swing(time, period: 1.9, delay: -0.95) : 0
            let right = rotated(bodyCtx, rightAngle, at: CGPoint(x: 77, y: 53))
            fill(right, "M77 53Q89 43 91 27L94 15Q98 8 101 14L100 30Q98 52 83 64Z", skin)
            var propCtx = right
            propCtx.translateBy(x: 97, y: 18)
            propCtx.scaleBy(x: 0.7, y: 0.7)
            PoolPropPainter.draw(a.prop, in: propCtx)
        }

        // 머리
        ctx.fill(Path(ellipseIn: CGRect(x: 60 - 23, y: 39 - 26, width: 46, height: 52)), with: .color(skin))
        if a.hair != "none" {
            switch a.hair {
            case "curly":
                fill(ctx, "M39 48Q27 41 36 33Q27 24 38 20Q36 8 48 13Q53 1 62 11Q73 3 80 17Q94 19 83 31Q91 41 80 48Q61 40 39 48Z", hair)
            case "bob":
                fill(ctx, "M37 43Q28 11 60 10Q92 11 83 43L87 56Q77 61 73 48Q60 40 47 48Q43 61 33 56Z", hair)
            default:
                fill(ctx, "M37 37Q32 11 60 10Q88 11 83 37Q69 30 60 34Q50 29 37 37Z", hair)
            }
            if a.hair == "bun" {
                ctx.fill(Path(ellipseIn: CGRect(x: 49, y: 1, width: 22, height: 22)), with: .color(hair))
            }
            stroke(ctx, "M47 20Q56 14 66 18", AvatarPalette.mix(a.hairColor, 0xFCFCFC, 0.2), 3)
        }
        if floating {
            ctx.fill(Path(ellipseIn: CGRect(x: 49, y: 43, width: 4, height: 4)), with: .color(AvatarPalette.ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 67, y: 43, width: 4, height: 4)), with: .color(AvatarPalette.ink))
            stroke(ctx, "M55 54Q60 58 65 54", AvatarPalette.ink, 2, cap: .butt)
        }
        if a.eyewear == "snorkel" {
            let mask = Path(roundedRect: CGRect(x: 39, y: 38, width: 42, height: 15), cornerRadius: 5)
            ctx.fill(mask, with: .color(AvatarPalette.mask.opacity(0.15)))
            ctx.stroke(mask, with: .color(AvatarPalette.color("blue")), lineWidth: 3)
            stroke(ctx, "M76 53H86Q91 53 91 47V16", AvatarPalette.color("blue"), 5)
            stroke(ctx, "M91 12V20", AvatarPalette.color("lemon"), 6)
        } else if a.eyewear != "none" {
            let ink = AvatarPalette.ink
            var lenses = Path()
            if a.eyewear == "round" {
                lenses.addEllipse(in: CGRect(x: 42, y: 38, width: 14, height: 14))
                lenses.addEllipse(in: CGRect(x: 64, y: 38, width: 14, height: 14))
            } else {
                lenses.addRoundedRect(in: CGRect(x: 41, y: 39, width: 16, height: 12), cornerSize: CGSize(width: 3, height: 3))
                lenses.addRoundedRect(in: CGRect(x: 63, y: 39, width: 16, height: 12), cornerSize: CGSize(width: 3, height: 3))
            }
            if a.eyewear == "sun" { ctx.fill(lenses, with: .color(ink)) }
            ctx.stroke(lenses, with: .color(ink), lineWidth: 2.5)
            stroke(ctx, "M56 45H64", ink, 2.5, cap: .butt)
        }
    }

    /// 디자인의 pool-stroke 키프레임 (-12° → 20° → -12°, ease-in-out)
    static func swing(_ t: Double, period: Double, delay: Double) -> Double {
        let phase = ((t - delay) / period).truncatingRemainder(dividingBy: 1)
        let p = phase < 0 ? phase + 1 : phase
        return -12 + 32 * (0.5 - 0.5 * cos(2 * .pi * p))
    }

    static func rotated(_ ctx: GraphicsContext, _ degrees: Double, at origin: CGPoint) -> GraphicsContext {
        var c = ctx
        c.translateBy(x: origin.x, y: origin.y)
        c.rotate(by: .degrees(degrees))
        c.translateBy(x: -origin.x, y: -origin.y)
        return c
    }

    static func fill(_ ctx: GraphicsContext, _ d: String, _ color: Color, evenOdd: Bool = false) {
        ctx.fill(SVGPath.path(d), with: .color(color), style: FillStyle(eoFill: evenOdd))
    }

    static func stroke(_ ctx: GraphicsContext, _ d: String, _ color: Color, _ width: CGFloat, cap: CGLineCap = .round) {
        ctx.stroke(SVGPath.path(d), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round))
    }
}

/// 튜브 (기본·플라밍고·돌고래). 120×160 좌표계
enum PoolFloatPainter {
    enum Layer { case all, back, front }

    static func draw(_ a: Avatar, layer: Layer, in base: GraphicsContext) {
        guard a.float != "none" else { return }
        var ctx = base
        switch layer {
        case .back: ctx.clip(to: Path(CGRect(x: -10, y: -10, width: 160, height: 90)))
        case .front: ctx.clip(to: Path(CGRect(x: -10, y: 80, width: 160, height: 90)))
        case .all: break
        }
        let colorHex = AvatarPalette.hex(a.floatColor)
        let color = Color(hex: colorHex)
        let shade = AvatarPalette.mix(colorHex, 0x1B1F29, 0.18)
        let light = AvatarPalette.mix(colorHex, 0xFCFCFC, 0.30)
        typealias P = PoolCharacterPainter

        P.fill(ctx, "M16 85C16 58 35 45 60 45S104 58 104 85S85 127 60 127S16 112 16 85ZM40 85C40 98 47 106 60 106S80 98 80 85S73 64 60 64S40 72 40 85Z", shade, evenOdd: true)
        P.fill(ctx, "M16 80C16 53 35 40 60 40S104 53 104 80S85 122 60 122S16 107 16 80ZM40 80C40 93 47 101 60 101S80 93 80 80S73 59 60 59S40 67 40 80Z", color, evenOdd: true)
        P.stroke(ctx, "M28 68Q31 52 47 49M77 110Q94 102 95 88", light, 5)
        if a.float == "flamingo" {
            P.fill(ctx, "M88 89Q118 74 105 49Q89 22 95 9Q101 -3 113 6Q125 14 115 29Q108 38 116 51Q131 79 109 97Z", color)
            P.fill(ctx, "M109 15L128 22L122 32L108 25Z", AvatarPalette.white)
            P.fill(ctx, "M122 20L132 24L122 32Z", AvatarPalette.ink)
            ctx.fill(Path(ellipseIn: CGRect(x: 105.5, y: 8.5, width: 7, height: 7)), with: .color(AvatarPalette.ink))
            P.fill(ctx, "M21 75Q7 87 19 100L29 91Z", light)
        } else if a.float == "dolphin" {
            P.fill(ctx, "M84 83Q89 65 85 43Q80 26 94 19Q110 13 119 27L135 31Q144 36 133 41L117 42Q114 58 107 75L106 90Z", color)
            P.fill(ctx, "M98 39Q112 47 124 36Q116 58 101 64Z", light)
            ctx.fill(Path(ellipseIn: CGRect(x: 110.5, y: 25.5, width: 7, height: 7)), with: .color(AvatarPalette.ink))
            P.fill(ctx, "M91 24L88 8Q87 3 97 9L107 18Z", color)
            P.fill(ctx, "M19 75L4 59Q0 57 3 67L14 91M101 75L116 59Q120 57 117 67L106 91", color)
            P.fill(ctx, "M54 119Q40 125 36 139L60 132L84 139Q80 125 66 119Z", color)
        }
    }
}

/// 손에 든 소품 (칵테일·주스·물총). 원점 기준 좌표
enum PoolPropPainter {
    static func draw(_ prop: String, in ctx: GraphicsContext) {
        typealias P = PoolCharacterPainter
        let c = AvatarPalette.color
        switch prop {
        case "cocktail":
            P.fill(ctx, "M-10 -13H10L0 0Z", AvatarPalette.white)
            P.fill(ctx, "M-8 -10H8L0 -1Z", c("rose"))
            P.stroke(ctx, "M0 0V12M-6 12H6", AvatarPalette.white, 3)
            ctx.fill(Path(ellipseIn: CGRect(x: 4, y: -16, width: 8, height: 8)), with: .color(c("lemon")))
            P.fill(ctx, "M-6 -14L-1 -23L10 -16Z", c("mint"))
            P.stroke(ctx, "M0 -19L3 -10", AvatarPalette.ink, 1.5, cap: .butt)
        case "juice":
            P.fill(ctx, "M-10 -15H10L7 12H-7Z", AvatarPalette.white)
            P.fill(ctx, "M-8 -9H8L6 10H-6Z", c("gold"))
            P.stroke(ctx, "M0 4L3 -23H9", c("rose"), 3)
            ctx.fill(Path(ellipseIn: CGRect(x: -12, y: -19, width: 10, height: 10)), with: .color(c("lemon")))
        case "watergun":
            ctx.fill(Path(roundedRect: CGRect(x: -17, y: -8, width: 29, height: 14), cornerRadius: 4), with: .color(c("lemon")))
            ctx.fill(Path(roundedRect: CGRect(x: -12, y: -15, width: 16, height: 10), cornerRadius: 4), with: .color(c("mint")))
            P.fill(ctx, "M-9 4H0L-2 17H-10Z", c("blue"))
            ctx.fill(Path(roundedRect: CGRect(x: 10, y: -5, width: 10, height: 7), cornerRadius: 2), with: .color(c("blue")))
            ctx.fill(Path(roundedRect: CGRect(x: -14, y: -5, width: 8, height: 5), cornerRadius: 2), with: .color(c("rose")))
        default:
            break
        }
    }
}
