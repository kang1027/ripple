import CoreLocation
import SwiftUI

struct RadarView: View {
    @Environment(AppState.self) private var app
    @Environment(LocationService.self) private var location
    @State private var count = 0
    @State private var avatars: [String?] = []
    @State private var radiusM = 200
    @State private var spots: [RadarSpot] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var joining = false
    @State private var error: String?

    // 반경이 10m까지 좁아서 멀어지고 다가오는 게 바로 보이도록 짧게 잡음. 위치 전송은 AppState.presenceLoop
    private let nearbyEvery: TimeInterval = 2

    var body: some View {
        VStack(spacing: 16) {
            radar
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(statusText(at: context.date))
                    .font(.subheadline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.settle(), value: statusText(at: context.date))
            }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.destructive) }
            ShadButton(title: "채팅하기", isLoading: joining) { Task { await join() } }
                .disabled(count == 0)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .task { await loop() }
    }

    private func statusText(at now: Date) -> String {
        switch location.authorization {
        case .denied, .restricted: return "설정에서 위치 권한을 허용해 주세요"
        default: break
        }
        if location.location == nil { return "위치를 확인하는 중이에요" }
        let revealed = spots.filter { $0.revealAt <= now }.count
        if count == 0 || revealed == 0 { return "주변 \(radiusM)m에서 찾는 중…" }
        // 아직 레이더가 안 지나간 사람이 있으면 나온 만큼만 센다
        return "주변 \(revealed < spots.count ? revealed : count)명을 찾았어요"
    }

    private var radar: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            TimelineView(.animation) { context in
                let now = context.date
                let sweep = Self.sweepAngle(at: now)
                ZStack {
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        let outer = side / 2 * 0.98
                        for f in [0.33, 0.66, 0.98] {
                            let r = side / 2 * f
                            ctx.stroke(
                                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                with: .color(Theme.border), lineWidth: 1
                            )
                        }
                        // 가운데에서 퍼지는 파동
                        if !reduceMotion {
                            let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                            let r = 30 + (outer - 30) * phase
                            ctx.stroke(
                                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                with: .color(Theme.foreground.opacity(0.10 * (1 - phase))), lineWidth: 1.5
                            )
                        }
                        // 레이더 꼬리: 지나간 자리가 흐려지며 남는다
                        let slices = 36
                        let tail = Double.pi / 3
                        for i in 0..<slices {
                            let a0 = sweep - tail * Double(i + 1) / Double(slices)
                            let a1 = sweep - tail * Double(i) / Double(slices)
                            var wedge = Path()
                            wedge.move(to: c)
                            wedge.addLine(to: CGPoint(x: c.x + cos(a0) * outer, y: c.y + sin(a0) * outer))
                            wedge.addLine(to: CGPoint(x: c.x + cos(a1) * outer, y: c.y + sin(a1) * outer))
                            wedge.closeSubpath()
                            let k = 1 - Double(i) / Double(slices)
                            ctx.fill(wedge, with: .color(Theme.foreground.opacity(0.07 * k * k)))
                        }
                        var line = Path()
                        line.move(to: c)
                        line.addLine(to: CGPoint(x: c.x + cos(sweep) * outer, y: c.y + sin(sweep) * outer))
                        ctx.stroke(line, with: .color(Theme.foreground.opacity(0.22)), lineWidth: 1.2)
                    }
                    ForEach(spots) { spot in
                        RadarBlip(spot: spot, now: now, sweep: sweep, reduceMotion: reduceMotion)
                            .position(
                                x: center.x + cos(spot.angle) * spot.radius * side / 2,
                                y: center.y + sin(spot.angle) * spot.radius * side / 2
                            )
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                    VStack(spacing: 4) {
                        ShadAvatar(url: app.me?.avatarUrl, size: 52)
                        Text("나").font(.caption).foregroundStyle(Theme.mutedForeground)
                    }
                    .position(center)
                }
            }
        }
        .padding(16)
    }

    private func loop() async {
        location.start()
        var lastNearby = Date.distantPast
        while !Task.isCancelled {
            if location.location != nil, !location.isBackground {
                if Date().timeIntervalSince(lastNearby) >= nearbyEvery {
                    lastNearby = Date()
                    if let out: NearbyOut = try? await app.api.request("GET", "/nearby") {
                        count = out.count
                        avatars = out.avatars
                        radiusM = out.radiusM
                        syncSpots(out.avatars)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func join() async {
        joining = true
        defer { joining = false }
        error = nil
        // 서버 위치가 60초 지나 만료됐으면 409라서, 입장 직전에 지금 위치를 한 번 더 보낸다
        if let loc = location.location {
            let body = ["lat": loc.coordinate.latitude, "lng": loc.coordinate.longitude, "accuracy": loc.horizontalAccuracy]
            let _: PresenceOut? = try? await app.api.request("POST", "/presence", body: body)
        }
        do {
            let room: RoomOut = try await app.api.request("POST", "/rooms/join")
            app.path.append(.room(room))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 레이더 한 바퀴 3.6초. 화면 좌표(y 아래) 기준 각도라 커질수록 시계 방향으로 돈다
    static let sweepSpeed = 2 * Double.pi / 3.6

    static func sweepAngle(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate * sweepSpeed).truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// 있던 사람 자리는 그대로 두고, 새로 잡힌 사람은 레이더가 그 자리를 지나갈 때 나오게 한다.
    /// 자리는 실제 방향·거리와 무관한 무작위 (위치 노출 방지)
    private func syncSpots(_ urls: [String?]) {
        let keys = urls.prefix(8).enumerated().map { i, url in url ?? "none-\(i)" }
        let urlByKey = Dictionary(zip(keys, urls.prefix(8)), uniquingKeysWith: { a, _ in a })
        var next = spots.filter { keys.contains($0.id) }
        let now = Date()
        for key in keys where !next.contains(where: { $0.id == key }) {
            let (angle, radius) = Self.freeSpot(avoiding: next)
            let wait = reduceMotion ? 0 : Self.wrap(angle - Self.sweepAngle(at: now)) / Self.sweepSpeed
            let spot = RadarSpot(id: key, url: urlByKey[key] ?? nil, angle: angle, radius: radius, revealAt: now.addingTimeInterval(wait))
            next.append(spot)
            Task {
                try? await Task.sleep(for: .seconds(wait))
                if spots.contains(where: { $0.id == key }) { Haptics.select() }
            }
        }
        withAnimation(Motion.settle()) { spots = next }
    }

    /// 후보 몇 개 중 이미 있는 사람과 가장 먼 자리
    static func freeSpot(avoiding others: [RadarSpot]) -> (Double, Double) {
        var best = (0.0, 0.6)
        var bestGap = -1.0
        for _ in 0..<16 {
            let a = Double.random(in: 0..<(2 * .pi))
            let r = Double.random(in: 0.42...0.86)
            let gap = others.map { o in hypot(cos(a) * r - cos(o.angle) * o.radius, sin(a) * r - sin(o.angle) * o.radius) }.min() ?? 1
            if gap > bestGap { bestGap = gap; best = (a, r) }
        }
        return best
    }

    static func wrap(_ a: Double) -> Double {
        let m = a.truncatingRemainder(dividingBy: 2 * .pi)
        return m < 0 ? m + 2 * .pi : m
    }
}

struct RadarSpot: Identifiable, Equatable {
    let id: String
    let url: String?
    let angle: Double
    let radius: Double
    let revealAt: Date
}

/// 레이더가 지나가면 뿅 튀어나오고, 다음 바퀴부터는 지나갈 때마다 작은 링이 퍼진다
private struct RadarBlip: View {
    let spot: RadarSpot
    let now: Date
    let sweep: Double
    let reduceMotion: Bool

    private let size: CGFloat = 34

    var body: some View {
        let t = now.timeIntervalSince(spot.revealAt)
        let popped = t >= 0
        let scale = reduceMotion ? 1 : (popped ? Self.easeOutBack(min(t / 0.42, 1)) : 0)
        // 처음 나올 때 크게, 그다음 바퀴부터는 작게
        let since = popped ? RadarView.wrap(sweep - spot.angle) / RadarView.sweepSpeed : .infinity
        let ring: (Double, Double)? = {
            guard popped, !reduceMotion else { return nil }
            if t < 0.9 { return (t / 0.9, 0.35) }
            if since < 0.7 { return (since / 0.7, 0.16) }
            return nil
        }()
        ZStack {
            if let (p, alpha) = ring {
                Circle()
                    .stroke(Theme.foreground.opacity(alpha * (1 - p)), lineWidth: 1.5)
                    .frame(width: size + 34 * Self.easeOut(p), height: size + 34 * Self.easeOut(p))
            }
            ShadAvatar(url: spot.url, size: size)
                .shadow(color: .black.opacity(popped ? 0.10 : 0), radius: 6, y: 2)
                .scaleEffect(scale)
                .opacity(popped ? 1 : 0)
        }
        .frame(width: size + 40, height: size + 40)
    }

    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.9, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}
