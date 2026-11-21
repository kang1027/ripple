import CoreLocation
import SwiftUI

/// 홈: 주변 사람들이 캐릭터로 헤엄치는 수영장 (디자인 HomeScreen).
/// 위치 전송은 AppState.presenceLoop가 하고, 여기서는 /nearby만 주기적으로 부른다.
struct RadarView: View {
    @Environment(AppState.self) private var app
    @Environment(LocationService.self) private var location
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 0
    @State private var avatars: [String?] = []
    @State private var characters: [Avatar?] = []
    @State private var areaName: String?
    @State private var radiusM = 200
    @State private var joining = false
    @State private var error: String?
    @State private var showJoin = false
    @State private var pool = PoolSimulation()
    @State private var poolRect: CGRect = .zero
    @State private var myAvatar = AvatarStore.load()
    @AppStorage("ripple.locationIntroSeen") private var introSeen = false
    @State private var showIntro = false

    // 반경이 좁아서 멀어지고 다가오는 게 바로 보이도록 짧게 잡음. 위치 전송은 AppState.presenceLoop
    private let nearbyEvery: TimeInterval = 2

    private var locationDenied: Bool {
        location.authorization == .denied || location.authorization == .restricted
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                    let t = pool.time(at: timeline.date, reduceMotion: reduceMotion)
                    let frame = pool.advance(to: t)
                    PoolStage(
                        frame: frame,
                        time: t,
                        floorCount: count + 1,
                        floorCenterY: poolRect.midY,
                        scheme: scheme
                    )
                }
                .gesture(poolGesture)

                content(safeTop: geo.safeAreaInsets.top, safeBottom: geo.safeAreaInsets.bottom)
            }
            .coordinateSpace(name: PoolSimulation.space)
            .ignoresSafeArea()
            .onAppear { pool.screenHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom }
        }
        .onChange(of: poolRect) { syncPool() }
        .onChange(of: count) { syncPool() }
        .onChange(of: characters) { syncPool() }
        .onAppear {
            myAvatar = app.me?.avatar ?? AvatarStore.load()
            syncPool()
        }
        .sheet(isPresented: $showJoin) { joinSheet }
        .fullScreenCover(isPresented: $showIntro) {
            LocationIntroView(
                onAllow: {
                    introSeen = true
                    showIntro = false
                    location.start()
                },
                onLater: {
                    introSeen = true
                    showIntro = false
                }
            )
        }
        .task { await loop() }
    }

    // MARK: 화면 글자·버튼

    private func content(safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, safeTop + 24)
            VStack(spacing: 8) {
                (Text("지금, ") + Text("같은 파동").font(AppFont.size(23, .bold)) + Text(" 안에"))
                    .appFont(23, .semibold)
                Text("가까이 있는 사람들과 가볍게 이어져요")
                    .appFont(12)
                    .opacity(0.75)
            }
            .foregroundStyle(Theme.Water.lettering)
            .padding(.top, 32)
            .allowsHitTesting(false)

            Color.clear
                .frame(minHeight: 210)
                .frame(maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(PoolSimulation.space))
                } action: { rect in
                    poolRect = rect
                }
                .allowsHitTesting(false)

            footer
                .padding(.horizontal, 20)
                .padding(.bottom, safeBottom + 24)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image("RippleLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                    Text("Ripple").appFont(28, .black)
                }
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10, weight: .semibold))
                    Text(placeLine).appFont(12, .medium)
                }
                .opacity(0.75)
            }
            .foregroundStyle(Theme.Water.lettering)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            Spacer()
        }
    }

    private var placeLine: String {
        if locationDenied || location.authorization == .notDetermined { return "위치를 확인할 수 없어요" }
        if location.location == nil { return "위치를 확인하는 중이에요" }
        return areaName ?? "내 주변 \(radiusM)m"
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 16) {
            if let error {
                Text(error)
                    .appFont(12, .medium)
                    .foregroundStyle(Theme.Water.lettering)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                if !locationDenied && count > 0 { LiveDot() }
                Text(statusLine)
            }
            .appFont(12, .medium)
            .foregroundStyle(Theme.Water.lettering.opacity(0.75))
            .allowsHitTesting(false)

            if location.authorization == .notDetermined {
                WaterButton(title: "위치 허용하기", systemImage: nil) { location.start() }
            } else if locationDenied {
                WaterButton(title: "설정에서 위치 켜기", systemImage: nil) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } else {
                WaterButton(title: "\(RoomName.short(areaName)) 리플 참여하기", systemImage: "arrow.up.right", isLoading: joining) {
                    Haptics.tap()
                    showJoin = true
                }
                .disabled(count == 0 || location.location == nil)
            }
        }
    }

    private var statusLine: String {
        if locationDenied || location.authorization == .notDetermined { return "위치를 켜면 근처에 있는 사람들이 물에 들어와요" }
        if location.location == nil { return "위치를 확인하는 중이에요" }
        if count == 0 { return "아직 혼자 떠 있어요" }
        return "주변에 \(count)명이 함께 떠 있어요"
    }

    // MARK: 참여 시트

    private var joinSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.tap()
                showJoin = false
                Task { await join() }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text("지금 이곳 · ripplers \(count + 1)명")
                        .appFont(12, .semibold)
                        .opacity(0.8)
                    Text("\(RoomName.short(areaName))\n리플 참여하기")
                        .appFont(26, .heavy)
                        .lineSpacing(2)
                        .padding(.top, 8)
                    HStack(spacing: 4) {
                        Text("바로 들어가기").appFont(14, .bold)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.background))
                    .padding(.top, 20)
                }
                .foregroundStyle(Theme.storyForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .background(CoverGradient(style: 2))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl))
            }
            .buttonStyle(PressStyle(scale: 0.98))
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .presentationDetents([.height(250)])
        .presentationCornerRadius(Theme.Radius.sheet)
        .presentationBackground(Theme.popover)
        .presentationDragIndicator(.visible)
    }

    // MARK: 물 만지기·캐릭터 집기

    private var poolGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(PoolSimulation.space))
            .onChanged { value in
                let t = pool.time(at: .now, reduceMotion: reduceMotion)
                // 시작 위치가 다르면 새 터치. 앞 터치가 팝업·시트로 취소돼 onEnded가 안 불렸어도 여기서 새로 시작한다
                if pool.gestureStart == value.startLocation {
                    pool.moveHeld(to: value.location, time: t)
                } else {
                    pool.gestureStart = value.startLocation
                    pool.dropHeld(time: t)
                    if pool.grab(at: value.location, time: t) {
                        Haptics.tap()
                    } else if !reduceMotion {
                        pool.addTouch(at: value.location, time: t)
                    }
                }
            }
            .onEnded { value in
                let t = pool.time(at: .now, reduceMotion: reduceMotion)
                if pool.release(at: value.location, velocity: value.velocity, time: t) {
                    Haptics.select()
                }
                pool.gestureStart = nil
            }
    }

    private func syncPool() {
        let others = min(count, 11)
        let ids = (0..<others).map { i in (i < avatars.count ? avatars[i] : nil) ?? "rippler-\(i)" }
        let fallback = Avatar.distinctPool(ids: ids, ownColor: myAvatar.floatColor)
        // 서버에 저장된 캐릭터가 있으면 그대로, 없으면 id로 정한 캐릭터
        let otherAvatars = fallback.enumerated().map { i, a in (i < characters.count ? characters[i] : nil) ?? a }
        let people = [myAvatar] + otherAvatars
        pool.configure(avatars: people, rect: poolRect)
    }

    // MARK: 데이터

    private func loop() async {
        // 아직 위치를 물어보지 않았으면 안내 화면을 먼저 보여주고, 허용을 누를 때 시스템 권한을 묻는다
        if location.authorization == .notDetermined && !introSeen {
            showIntro = true
        } else if location.authorization != .notDetermined || introSeen {
            location.start()
        }
        var lastNearby = Date.distantPast
        while !Task.isCancelled {
            if location.location != nil, !location.isBackground {
                if Date().timeIntervalSince(lastNearby) >= nearbyEvery {
                    lastNearby = Date()
                    if let out: NearbyOut = try? await app.api.request("GET", "/nearby") {
                        count = out.count
                        avatars = out.avatars
                        characters = out.characters ?? []
                        areaName = out.areaName
                        radiusM = out.radiusM
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
}

// MARK: - 수영장 그림

/// 물(셰이더) + 캐릭터. 좌표는 화면 전체 기준
private struct PoolStage: View {
    let frame: PoolFrameSnapshot
    let time: Double
    let floorCount: Int
    let floorCenterY: CGFloat
    let scheme: ColorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            PoolWater(time: time, swimmers: frame.shaderSwimmers, touches: frame.shaderTouches,
                      count: floorCount, floorCenterY: floorCenterY, scheme: scheme)
            ForEach(frame.swimmers) { s in
                SwimmerView(swimmer: s, time: time)
                    .position(x: s.x, y: s.y)
            }
        }
    }
}

private struct SwimmerView: View {
    let swimmer: PoolFrameSnapshot.Swimmer
    let time: Double

    var body: some View {
        let wiggle = swimmer.held ? (sin(time * .pi / 0.18) * 7) : 0
        let landing = swimmer.landingProgress
        let lift: CGFloat = swimmer.held ? -14 : (landing.map { -14 * (1 - $0) + 3 * sin(.pi * $0) } ?? 0)
        let scale: CGFloat = swimmer.held ? 1.16 : (landing.map { 1.16 - 0.16 * $0 - 0.1 * sin(.pi * $0) } ?? 1)
        ZStack {
            PoolCharacterView(avatar: swimmer.avatar, time: swimmer.held ? time * 10 : time)
                .rotationEffect(.degrees(wiggle))
                .scaleEffect(scale)
                .offset(y: lift)
                .shadow(color: Color(hex: 0x1B3E5C, alpha: swimmer.held ? 0.12 : 0.18), radius: swimmer.held ? 6 : 2.5, y: swimmer.held ? 4 : 9)
                .rotationEffect(.degrees(swimmer.rotation))
            if swimmer.isMe {
                Text("나")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Water.lettering)
                    .offset(y: 25 + 8 - 6)
            }
        }
        .frame(width: 32, height: 50)
        .allowsHitTesting(false)
    }
}

/// 수영장 바닥(타일 + 인원수)을 그리고 셰이더로 물을 얹는다
private struct PoolWater: View {
    let time: Double
    let swimmers: [Float]
    let touches: [Float]
    let count: Int
    let floorCenterY: CGFloat
    let scheme: ColorScheme

    var body: some View {
        let raw = Theme.Water.raw(scheme)
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Water.floor))
            var grid = Path()
            let tile: CGFloat = 32.25
            var x: CGFloat = 0
            while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += tile }
            var y: CGFloat = 0
            while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += tile }
            ctx.stroke(grid, with: .color(Theme.Water.grout), lineWidth: 0.75)

            let center = floorCenterY > 0 ? floorCenterY : size.height * 0.53
            let number = ctx.resolve(Text("\(count)").font(AppFont.size(90.7, .heavy)).foregroundStyle(Theme.Water.lettering))
            ctx.draw(number, at: CGPoint(x: size.width / 2, y: center - 7.6), anchor: .center)
            let label = ctx.resolve(Text("지금 이곳의 ripplers").font(AppFont.size(12.1, .semibold)).foregroundStyle(Theme.Water.lettering))
            ctx.draw(label, at: CGPoint(x: size.width / 2, y: center + 52.9), anchor: .center)
        }
        .layerEffect(
            ShaderLibrary.poolWater(
                .boundingRect,
                .float(Float(time)),
                .floatArray(swimmers),
                .floatArray(touches),
                .float3(Self.rgb(raw.deep)),
                .float3(Self.rgb(raw.shallow)),
                .float3(Self.rgb(raw.highlight))
            ),
            maxSampleOffset: CGSize(width: 28, height: 28)
        )
        .accessibilityElement()
        .accessibilityLabel("\(count)명이 새겨진 수영장 바닥 위로 일렁이는 물결")
    }

    static func rgb(_ hex: UInt32) -> (Float, Float, Float) {
        (Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }
}

private extension Shader.Argument {
    static func float3(_ v: (Float, Float, Float)) -> Shader.Argument { .float3(v.0, v.1, v.2) }
}

// MARK: - 시뮬레이션 상태

/// 한 프레임에 그릴 값 묶음
struct PoolFrameSnapshot {
    struct Swimmer: Identifiable {
        let id: Int
        let avatar: Avatar
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
        let held: Bool
        let isMe: Bool
        let landingProgress: Double?
    }

    var swimmers: [Swimmer] = []
    var shaderSwimmers: [Float] = [-10, -10, 0]
    var shaderTouches: [Float] = [-10, -10, -10]
}

/// 캐릭터 몸·물결 터치 상태. 화면이 다시 그려질 때마다 바뀌므로 관찰 대상이 아닌 클래스로 둔다
final class PoolSimulation {
    static let space = "pool-home"

    var screenHeight: CGFloat = 852
    /// 지금 진행 중인 터치의 시작 위치
    var gestureStart: CGPoint?
    private var start = Date()
    private var avatars: [Avatar] = []
    private var bodies: [PoolBody] = []
    private var rect: CGRect = .zero
    private var touches: [PoolTouch] = []
    private var lastStep: Double = -1
    private var held: (index: Int, x: Double, y: Double)?
    private var landings: [Int: Double] = [:]
    private var snapshot = PoolFrameSnapshot()

    func time(at date: Date, reduceMotion: Bool) -> Double {
        reduceMotion ? 1.5 : date.timeIntervalSince(start)
    }

    func configure(avatars next: [Avatar], rect nextRect: CGRect) {
        guard nextRect.width > 0, nextRect.height > 0 else { avatars = next; return }
        let resized = nextRect.size != rect.size
        if resized || bodies.isEmpty {
            bodies = next.indices.map { i in PoolMotion.createBody(index: i, width: nextRect.width, height: nextRect.height, floating: next[i].isFloating) }
        } else if next.count > bodies.count {
            for i in bodies.count..<next.count {
                bodies.append(PoolMotion.createBody(index: i, width: nextRect.width, height: nextRect.height, floating: next[i].isFloating))
            }
        } else if next.count < bodies.count {
            bodies.removeLast(bodies.count - next.count)
        }
        if let h = held, h.index >= next.count { held = nil }
        avatars = next
        rect = nextRect
        lastStep = -1
    }

    /// 물리는 디자인처럼 초당 30번만 계산하고, 그리는 건 매 프레임 한다
    func advance(to t: Double) -> PoolFrameSnapshot {
        guard rect.width > 0, !bodies.isEmpty else { return snapshot }
        if lastStep < 0 || t - lastStep >= 1.0 / 30 || t < lastStep {
            lastStep = t
            touches = touches.filter { t - $0.time < 6 }
            let local = touches.map { PoolTouch(x: $0.x - rect.minX, y: $0.y - rect.minY, time: $0.time) }
            for i in bodies.indices {
                if let h = held, h.index == i {
                    var b = bodies[i]
                    b.x = h.x - rect.minX; b.y = h.y - rect.minY
                    b.vx = 0; b.vy = 0; b.lastTime = t; b.push = 0
                    bodies[i] = b
                } else {
                    bodies[i] = PoolMotion.step(bodies[i], time: t, width: rect.width, height: rect.height,
                                                floating: avatars[i].isFloating, touches: local, waveHeight: screenHeight)
                }
            }
            landings = landings.filter { t - $0.value < 0.42 }
        }
        snapshot = makeSnapshot(t)
        return snapshot
    }

    private func makeSnapshot(_ t: Double) -> PoolFrameSnapshot {
        let w = Double(rect.maxX + rect.minX) // 화면 폭 (풀 영역은 좌우 대칭)
        let h = Double(screenHeight)
        let aspect = w / max(h, 1)
        var frame = PoolFrameSnapshot()
        var swim: [Float] = []
        for (i, b) in bodies.enumerated() {
            let x = b.x + rect.minX, y = b.y + rect.minY
            frame.swimmers.append(.init(
                id: i, avatar: avatars[i], x: x, y: y, rotation: b.rotation,
                held: held?.index == i, isMe: i == 0,
                landingProgress: landings[i].map { min(max((t - $0) / 0.42, 0), 1) }
            ))
            swim += [Float((x / w - 0.5) * aspect), Float(0.5 - y / h), Float(i)]
        }
        frame.shaderSwimmers = swim.isEmpty ? [-10, -10, 0] : swim
        let tv = touches.suffix(6).flatMap { [Float(($0.x / w - 0.5) * aspect), Float(0.5 - $0.y / h), Float($0.time)] }
        frame.shaderTouches = tv.isEmpty ? [-10, -10, -10] : tv
        return frame
    }

    func addTouch(at p: CGPoint, time t: Double) {
        touches = Array((touches + [PoolTouch(x: p.x, y: p.y, time: t)]).suffix(6))
    }

    func grab(at p: CGPoint, time t: Double) -> Bool {
        guard held == nil else { return false }
        // 몸 가운데부터 머리 위쪽 28pt까지를 잡을 수 있는 영역으로 본다 (손가락이 캐릭터를 가리지 않게)
        var best: (Int, Double)?
        for (i, b) in bodies.enumerated() {
            let cx = b.x + rect.minX, cy = b.y + rect.minY
            let top = cy - 28
            let nearestY = min(max(p.y, top), cy)
            let d = hypot(cx - p.x, nearestY - p.y)
            if d < 34, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        guard let (index, _) = best else { return false }
        held = (index, clampX(p.x), clampY(p.y))
        return true
    }

    func moveHeld(to p: CGPoint, time t: Double) {
        guard let h = held else { return }
        held = (h.index, clampX(p.x), clampY(p.y))
    }

    /// 취소된 터치로 붙잡힌 채 남은 캐릭터를 제자리에 내려놓는다
    func dropHeld(time t: Double) {
        guard let h = held else { return }
        held = nil
        bodies[h.index].lastTime = t
    }

    func release(at p: CGPoint, velocity: CGSize, time t: Double) -> Bool {
        guard let h = held else { return false }
        let x = clampX(p.x), y = clampY(p.y)
        bodies[h.index] = PoolMotion.throwBody(bodies[h.index], x: x - rect.minX, y: y - rect.minY,
                                                vx: velocity.width, vy: velocity.height)
        bodies[h.index].lastTime = t
        held = nil
        landings[h.index] = t
        addTouch(at: CGPoint(x: x, y: y), time: t)
        return true
    }

    private func clampX(_ x: CGFloat) -> Double { Double(min(max(x, rect.minX + 40), rect.maxX - 40)) }
    private func clampY(_ y: CGFloat) -> Double { Double(min(max(y, rect.minY + 40), rect.maxY - 40)) }
}

// MARK: - 홈 부품

/// 물 위 주 버튼: 밝은 물빛 바탕 + 깊은 물색 글자
private struct WaterButton: View {
    let title: String
    let systemImage: String?
    var isLoading = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 6) {
                    Text(title).appFont(17, .bold)
                    if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .bold)) }
                }
                .opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(Theme.Water.deep) }
            }
            .foregroundStyle(Theme.Water.deep)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xxl).fill(Theme.Water.lettering))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(PressStyle())
        .disabled(isLoading)
    }
}

private struct LiveDot: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.Water.lettering)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.4 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
