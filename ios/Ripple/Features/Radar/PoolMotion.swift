import CoreGraphics
import Foundation

/// 홈 수영장 캐릭터 물리 (디자인 pool-motion.ts를 그대로 옮김).
/// 단위는 pt, 시간은 초. 처음 자리로 끌어당기는 힘은 일부러 없다.
struct PoolTouch: Equatable {
    var x: Double
    var y: Double
    var time: Double
}

struct PoolBody: Equatable {
    var x: Double
    var y: Double
    var rotation: Double
    var push: Double
    var vx: Double
    var vy: Double
    var lastTime: Double
    var hitWaves: [Double]
}

enum PoolMotion {
    static let characterSize: Double = 32
    static let padding: Double = 40

    static func throwBody(_ body: PoolBody, x: Double, y: Double, vx: Double, vy: Double) -> PoolBody {
        let speed = hypot(vx, vy)
        let scale = speed > 240 ? 240 / speed : 1
        var b = body
        b.x = x; b.y = y
        b.vx = vx * scale; b.vy = vy * scale
        b.hitWaves = []
        b.push = 0
        return b
    }

    static func createBody(index: Int, width: Double, height: Double, floating: Bool) -> PoolBody {
        let pos = position(index: index, time: 0, width: width, height: height, floating: floating)
        let angle = Double(index) * 2.17
        let speed: Double = floating ? 3 : 9
        return PoolBody(x: pos.x, y: pos.y, rotation: pos.rotation, push: pos.push,
                        vx: cos(angle) * speed, vy: sin(angle) * speed, lastTime: -1, hitWaves: [])
    }

    static func step(_ body: PoolBody, time: Double, width: Double, height: Double, floating: Bool,
                     touches: [PoolTouch] = [], waveHeight: Double? = nil) -> PoolBody {
        let waveH = waveHeight ?? height
        let dt = body.lastTime < 0 || time < body.lastTime ? 0 : min(time - body.lastTime, 0.08)
        var x = body.x, y = body.y, vx = body.vx, vy = body.vy
        var push: Double = 0
        var hitWaves = body.hitWaves.filter { stamp in touches.contains { $0.time == stamp } }
        for touch in touches {
            let age = time - touch.time
            if age <= 0 || age > 6 || hitWaves.contains(touch.time) { continue }
            let dx = x - touch.x, dy = y - touch.y
            let distance = hypot(dx, dy)
            if abs(distance - age * 0.16 * waveH) > 25 { continue }
            let strength = 65 * exp(-age * 0.28)
            vx += (distance > 1 ? dx / distance : 1) * strength
            vy += (distance > 1 ? dy / distance : 0) * strength
            hitWaves.append(touch.time)
            push = strength
        }
        let drag = exp(-dt * (floating ? 0.45 : 0.28))
        vx *= drag; vy *= drag
        if !floating {
            let speed = hypot(vx, vy)
            if speed > 0.01 && speed < 9 { vx *= 9 / speed; vy *= 9 / speed }
        }
        x += vx * dt; y += vy * dt
        let minX = min(padding, width / 2), maxX = max(width - padding, width / 2)
        let minY = min(padding, height / 2), maxY = max(height - padding, height / 2)
        if x < minX { x = minX; vx = abs(vx) * 0.85 }
        if x > maxX { x = maxX; vx = -abs(vx) * 0.85 }
        if y < minY { y = minY; vy = abs(vy) * 0.85 }
        if y > maxY { y = maxY; vy = -abs(vy) * 0.85 }
        let angle = atan2(vx, -vy) * 180 / .pi
        let rotation = floating ? body.rotation + sin(time * 0.8 + x * 0.01) * dt * 3 : angle
        return PoolBody(x: x, y: y, rotation: rotation, push: push, vx: vx, vy: vy, lastTime: time, hitWaves: hitWaves)
    }

    /// 처음 자리 (3열 × 4행 격자 + 흔들림)
    static func position(index: Int, time: Double, width: Double, height: Double, floating: Bool,
                         touches: [PoolTouch] = []) -> (x: Double, y: Double, rotation: Double, push: Double) {
        let usableW = max(0, width - padding * 2)
        let usableH = max(0, height - padding * 2)
        let cols = [0.12, 0.49, 0.86]
        let rows = [0.06, 0.31, 0.69, 0.94]
        let column = cols[index % 3]
        let row = rows[(index / 3) % 4]
        let speed = floating ? 0.14 : 0.27
        let phase = time * speed + Double(index) * 2.17
        let ampX = min(usableW * 0.085, floating ? 12 : 24)
        let ampY = min(usableH * 0.07, floating ? 10 : 20)
        var x = padding + column * usableW + sin(phase) * ampX
        var y = padding + row * usableH + cos(phase * 0.8) * ampY
        var pushX: Double = 0, pushY: Double = 0
        for touch in touches {
            let age = time - touch.time
            if age <= 0 || age >= 6 { continue }
            let dx = x - touch.x, dy = y - touch.y
            let distance = hypot(dx, dy)
            let front = age * 0.16 * height
            let force = exp(-pow((distance - front) / 38, 2)) * exp(-age * 0.6) * min(age / 0.15, 1) * 18
            pushX += (distance > 1 ? dx / distance : 1) * force
            pushY += (distance > 1 ? dy / distance : 0) * force
        }
        let bob = sin(time * 1.2 + x * 0.018 - y * 0.013) * 1.8
        x += pushX; y += pushY + bob
        func clamp(_ n: Double, _ maxV: Double) -> Double {
            min(max(n, min(padding, maxV / 2)), max(maxV - padding, maxV / 2))
        }
        let heading = floating
            ? sin(phase * 0.7) * 18 + Double(index) * 29
            : atan2(cos(phase) * ampX, -sin(phase * 0.8) * ampY * 0.8) * 180 / .pi
        return (clamp(x, width), clamp(y, height), heading + bob * 2 + pushX * 0.8, hypot(pushX, pushY))
    }
}
