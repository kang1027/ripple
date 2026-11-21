import SwiftUI

/// 디자인 원본(SVG)의 path 문자열을 그대로 SwiftUI Path로 바꾼다.
/// 캐릭터 그림이 디자인과 똑같이 나오도록 좌표를 손으로 옮기지 않고 원문을 쓴다.
/// 지원: M L H V Q C S Z (대·소문자). 디자인 캐릭터 경로에 쓰인 명령만 다룬다.
enum SVGPath {
    nonisolated(unsafe) private static var cache: [String: Path] = [:]
    private static let lock = NSLock()

    static func path(_ d: String) -> Path {
        lock.lock()
        if let hit = cache[d] { lock.unlock(); return hit }
        lock.unlock()
        let built = parse(d)
        lock.lock()
        cache[d] = built
        lock.unlock()
        return built
    }

    private static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens = Tokenizer(d)
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicControl: CGPoint?

        while let next = tokens.peek() {
            if case .command(let c) = next {
                command = c
                tokens.advance()
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    lastCubicControl = nil
                    continue
                }
            }
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased() {
            case "M":
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                lastCubicControl = nil
                // M 뒤에 이어지는 좌표쌍은 L로 본다
                command = relative ? "l" : "L"
            case "L":
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastCubicControl = nil
            case "Q":
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p
                lastCubicControl = nil
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
            case "S":
                guard let c2 = point(), let p = point() else { return path }
                let c1: CGPoint
                if let last = lastCubicControl {
                    c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    c1 = current
                }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
            default:
                tokens.advance()
            }
        }
        return path
    }

    private struct Tokenizer {
        enum Token { case command(Character), number(CGFloat) }
        private let chars: [Character]
        private var index = 0

        init(_ s: String) { chars = Array(s) }

        mutating func peek() -> Token? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter { return .command(c) }
            return .number(0)
        }

        mutating func advance() { index += 1 }

        mutating func number() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }
            var text = ""
            var seenDot = false
            var seenExp = false
            if chars[index] == "-" || chars[index] == "+" { text.append(chars[index]); index += 1 }
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    text.append(c)
                } else if c == ".", !seenDot, !seenExp {
                    seenDot = true
                    text.append(c)
                } else if (c == "e" || c == "E"), !seenExp {
                    seenExp = true
                    text.append(c)
                    if index + 1 < chars.count, chars[index + 1] == "-" || chars[index + 1] == "+" {
                        index += 1
                        text.append(chars[index])
                    }
                } else {
                    break
                }
                index += 1
            }
            return Double(text).map { CGFloat($0) }
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" {
                index += 1
            }
        }
    }
}
