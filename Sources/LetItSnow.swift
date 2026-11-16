// Let It Snow — snow on your Mac desktop.
// Based on WinterIsComing by Shi Yike (MIT, https://github.com/yike-shi/WINTER_IS_COMING).
// Snow piles up on top of windows, the Dock and the bottom of the screen and flies off when you drag a
// window. Hover over the snow to roll snowballs, push them into each other, drag them with the mouse and
// stack three of them into a snowman. See README.md for the full list.
// Build: zsh build.sh   (creates build/Let It Snow.app)
// Run:   zsh build.sh --run   (a ❄︎ icon appears in the menu bar: pause / snow amount / login / updates / quit)

import Cocoa
import SpriteKit

// MARK: - Settings (feel free to tweak)

enum Cfg {
    static var targetFlakes = 260            // number of flakes falling at the same time
    static let pileOnWindows = false         // false: snow falls in front of windows and piles only at the bottom
                                             // of the screen and on the Dock. true: snow also piles on window tops
    static let colW: CGFloat = 3             // width of one column of the snow height map (px)
    static let windowPileMax: CGFloat = 16   // max snow height on top of a window
    static let groundPileMax: CGFloat = 34   // max snow height at the bottom of the screen
    static let gravity: CGFloat = 900        // gravity for snow sliding off
    static let pollInterval = 1.0 / 30.0     // how often window positions are checked (s)
    static let maxClumps = 900               // max number of falling snow clumps at once
    static let dockPileMax: CGFloat = 18     // max snow height on the Dock
    static let dockPad: CGFloat = 4          // extra width of the Dock pile on each side of the icon area
    static let dockTopOffset: CGFloat = -1   // lower it if the snow floats above the Dock, raise it if it sinks in
    static let fallSpeed: CGFloat = 1.5      // falling speed multiplier (1 = original, bigger = faster)
    static let flakesInFront = true          // some of the smallest flakes fall in front of windows, so they can reach the Dock
    static let inFrontFraction: CGFloat = 0.4 // share of the smallest layer that falls in front (0...1)
    static let ballStartRadius: CGFloat = 3  // a new snowball starts this small
    static let ballMaxRadius: CGFloat = 28   // and stops growing at this size
    static let maxBalls = 20                 // oldest resting snowballs are removed beyond this
    static let dockGain: CGFloat = 3.0       // snow landing on the Dock counts this many times more, so it builds up
    // Snowball physics
    static let rollFriction: CGFloat = 0.35  // rolling resistance in snow, as a share of gravity (higher = stops sooner)
    static let rollDrag: CGFloat = 3.0       // extra slowdown that grows with speed (1/s): hard knocks die out quickly
    static let plowDrag: CGFloat = 0.8       // extra resistance from snow piled up in front of a ball
    static let ballBounce: CGFloat = 0.2     // share of speed kept when balls bump into each other or the screen edge
    static let maxRollSpeed: CGFloat = 900   // fastest a ball can roll (px/s)
    static let ballCrackSpeed: CGFloat = 300 // a dropped ball lands whole below this impact speed (px/s, ~50 px drop)
    static let ballBurstSpeed: CGFloat = 700 // and bursts completely above this (~270 px drop); in between, part breaks off.
                                             // Both are for a 12 px ball: bigger balls break sooner, smaller ones later
    static let ballCushionDepth: CGFloat = 30 // this much fresh snow under a landing ball halves the impact
    static let ballSideKeep: CGFloat = 0.7   // share of a falling ball's sideways speed it keeps rolling with on landing
    static let reposeStep: CGFloat = 1.6     // steepest snow slope: max height step between two columns (px) before it slumps
}

// MARK: - Find the Dock (needs Accessibility permission)

@MainActor final class DockTracker {
    private var trusted = false
    private var warned = false
    var lastError = ""

    init() {
        // On first run macOS shows a prompt asking you to grant the permission
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Frame of the Dock icon area (global macOS coordinates, origin top-left); nil if unavailable
    func frame() -> CGRect? {
        if !trusted {
            trusted = AXIsProcessTrusted()
            if !trusted {
                if !warned {
                    warned = true
                    print("❄︎ For snow on the Dock: System Settings → Privacy & Security → Accessibility, enable Terminal (or whichever app you run this from), then restart.")
                }
                lastError = "no Accessibility permission"
                return nil
            }
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lastError = "Dock process not found"
            return nil
        }
        let axApp = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef)
        guard err == .success, let children = childrenRef as? [AXUIElement] else {
            lastError = "could not read Dock children (AXError \(err.rawValue))"
            return nil
        }
        var roles: [String] = []
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? "?"
            roles.append(role)
            guard role == kAXListRole else { continue }
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let pv = posRef, let sv = sizeRef,
                  CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            return CGRect(origin: pos, size: sz)
        }
        lastError = "no AXList among Dock children (roles: \(roles))"
        return nil
    }
}

// Three depth layers: far = small, faint, slow; near = big, bright, fast
struct Layer {
    let size: ClosedRange<CGFloat>
    let speed: ClosedRange<CGFloat>
    let alpha: ClosedRange<CGFloat>
    let sway: ClosedRange<CGFloat>
    let wind: CGFloat
    let z: CGFloat
}

let layers: [Layer] = [
    Layer(size: 1.8...3.0, speed: 22...38,  alpha: 0.30...0.50, sway: 5...10,  wind: 0.5, z: 1),
    Layer(size: 3.0...4.8, speed: 40...65,  alpha: 0.60...0.80, sway: 9...16,  wind: 0.8, z: 2),
    Layer(size: 4.8...7.5, speed: 70...105, alpha: 0.85...1.00, sway: 14...24, wind: 1.1, z: 7),
]

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }

// Soft round flake texture: solid center, fading edge
@MainActor func makeFlakeTexture() -> SKTexture {
    let s: CGFloat = 64
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.6),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.45, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        return true
    }
    return SKTexture(image: img)
}

// Snowball body: lit from the top-left, bluish shade at the bottom-right (this part never rotates)
@MainActor func makeSnowballTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))
        ctx.clip()
        let colors = [
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            CGColor(red: 0.94, green: 0.96, blue: 1.00, alpha: 1),
            CGColor(red: 0.68, green: 0.75, blue: 0.88, alpha: 1),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.55, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        ctx.drawRadialGradient(grad,
                               startCenter: CGPoint(x: s * 0.38, y: s * 0.64), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.55,
                               options: [.drawsAfterEndLocation])
        return true
    }
    return SKTexture(image: img)
}

// Little grey-blue specks on top of the body; this layer rotates so you can see the ball roll
@MainActor func makeSpeckTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 6, y: 6, width: s - 12, height: s - 12))
        ctx.clip()
        for _ in 0..<30 {
            let d = rnd(3, 8)
            ctx.setFillColor(CGColor(red: 0.66, green: 0.73, blue: 0.87, alpha: rnd(0.25, 0.55)))
            ctx.fillEllipse(in: CGRect(x: rnd(6, s - 14), y: rnd(6, s - 14), width: d, height: d))
        }
        return true
    }
    return SKTexture(image: img)
}

// MARK: - Snowball

@MainActor final class Snowball {
    let node = SKNode()
    let body: SKSpriteNode
    let specks: SKSpriteNode
    var x: CGFloat = 0
    var y: CGFloat = 0
    var r: CGFloat = Cfg.ballStartRadius
    weak var pile: Pile?         // the surface it rests on (nil while falling, dragged or stacked)
    weak var below: Snowball?    // the ball it is stacked on (snowman), if any
    var falling = false
    var dragging = false
    var vel = CGVector.zero      // while falling
    var vx: CGFloat = 0          // rolling speed along the surface it rests on
    var decor: SKNode?           // snowman face / scarf / buttons drawn on this ball
    var crushed = false          // flattened by a ball that fell on it; removed on the next step

    init(body bodyTex: SKTexture, specks speckTex: SKTexture) {
        body = SKSpriteNode(texture: bodyTex)
        specks = SKSpriteNode(texture: speckTex)
        specks.zPosition = 0.1
        specks.zRotation = rnd(0, 6.28)
        node.zPosition = 6.5
        node.addChild(body)
        node.addChild(specks)
    }

    func layout() {
        node.position = CGPoint(x: x, y: y)
        let d = CGSize(width: r * 2, height: r * 2)
        body.size = d
        specks.size = d
    }

    /// Weight, for collisions: grows with volume
    var mass: CGFloat { r * r * r }

    func drop(vel v: CGVector) {
        falling = true
        vx = 0
        dragging = false
        pile = nil
        below = nil
        vel = v
    }
}

// MARK: - Flake

@MainActor final class Flake {
    let node: SKSpriteNode
    var vel = CGVector.zero
    var size: CGFloat = 4
    var swayAmp: CGFloat = 0
    var swayFreq: CGFloat = 1
    var phase: CGFloat = 0
    var windFactor: CGFloat = 1
    var inFront = false          // true = falls in front of windows (ignores them), lands on Dock / ground
    var isClump = false          // true = clump sliding off a surface (affected by gravity)
    var ignoreID = -1            // don't land right back on the surface it came from
    var ignoreUntil: CGFloat = 0

    init(texture: SKTexture) { node = SKSpriteNode(texture: texture) }
}

// MARK: - Snow pile (a height map drawn as a smooth white mound)

@MainActor final class Pile {
    var minX: CGFloat
    var topY: CGFloat
    let width: CGFloat
    let maxH: CGFloat
    var h: [CGFloat]
    var caps: [CGFloat]          // max height per column, tapering at both ends so it looks rounded
    var occ: [Bool]              // whether this column is hidden behind a window in front
    let body = SKShapeNode()
    let shade = SKShapeNode()
    var dirty = false

    init(minX: CGFloat, topY: CGFloat, width: CGFloat, maxH: CGFloat, parent: SKNode) {
        self.minX = minX
        self.topY = topY
        self.width = width
        self.maxH = maxH
        let n = max(1, Int((width / Cfg.colW).rounded(.up)))
        h = Array(repeating: 0, count: n)
        occ = Array(repeating: false, count: n)
        caps = (0..<n).map { i in
            let edgeDist = min(CGFloat(i) + 0.5, CGFloat(n - i) - 0.5) * Cfg.colW
            let t = min(1, edgeDist / (maxH * 2.2))
            return maxH * t.squareRoot()
        }
        body.fillColor = NSColor(calibratedWhite: 1, alpha: 0.97)
        body.strokeColor = .clear
        body.lineWidth = 0
        body.zPosition = 5
        // light blue-grey layer underneath, like a shadow
        shade.fillColor = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 0.9)
        shade.strokeColor = .clear
        shade.lineWidth = 0
        shade.zPosition = 4
        shade.position = CGPoint(x: 0, y: -1.5)
        parent.addChild(shade)
        parent.addChild(body)
    }

    var count: Int { h.count }
    var total: CGFloat { h.reduce(0, +) }

    func col(at x: CGFloat) -> Int? {
        let c = Int((x - minX) / Cfg.colW)
        return (c >= 0 && c < count) ? c : nil
    }
    func colX(_ c: Int) -> CGFloat { minX + (CGFloat(c) + 0.5) * Cfg.colW }
    func surface(_ c: Int) -> CGFloat { topY + h[c] }

    func add(at c: Int, amount: CGFloat) {
        let spread: [(Int, CGFloat)] = [(0, 1), (-1, 0.75), (1, 0.75), (-2, 0.45), (2, 0.45), (-3, 0.2), (3, 0.2)]
        for (o, w) in spread {
            let i = c + o
            guard i >= 0, i < count, !occ[i] else { continue }
            h[i] = min(caps[i], h[i] + amount * w)
        }
        dirty = true
    }

    var sweepLeft = false

    /// Surface height at x (the bare base where there is no column)
    func surfaceAt(_ x: CGFloat) -> CGFloat {
        guard let c = col(at: x), !occ[c] else { return topY }
        return topY + h[c]
    }

    /// Add snow to a column up to its cap; returns what didn't fit
    @discardableResult
    func deposit(at c: Int, _ amount: CGFloat) -> CGFloat {
        guard c >= 0, c < count, !occ[c] else { return amount }
        let room = max(0, caps[c] - h[c])
        let put = min(room, amount)
        h[c] += put
        dirty = true
        return amount - put
    }

    // let snow slump sideways where the slope is steeper than snow can hold
    func relax() -> Bool {
        guard count > 1 else { return false }
        var moved = false
        sweepLeft.toggle()
        let idx: [Int] = sweepLeft ? Array((0..<(count - 1)).reversed()) : Array(0..<(count - 1))
        for i in idx where !occ[i] && !occ[i + 1] {
            let d = h[i] - h[i + 1]
            if abs(d) > Cfg.reposeStep {
                let m = (abs(d) - Cfg.reposeStep) * 0.3 * (d > 0 ? 1 : -1)
                h[i] = max(0, min(caps[i], h[i] - m))
                h[i + 1] = max(0, min(caps[i + 1], h[i + 1] + m))
                if abs(m) > 0.02 { moved = true }
            }
        }
        return moved
    }

    func clear() {
        for i in 0..<count { h[i] = 0 }
        dirty = true
    }

    func redraw() {
        guard dirty else { return }
        dirty = relax()
        if total < 0.5 {
            body.path = nil
            shade.path = nil
            return
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX, y: topY))
        for c in 0..<count { p.addLine(to: CGPoint(x: colX(c), y: topY + h[c])) }
        p.addLine(to: CGPoint(x: minX + width, y: topY))
        p.closeSubpath()
        body.path = p
        shade.path = p
    }

    func remove() {
        body.removeFromParent()
        shade.removeFromParent()
    }
}

// MARK: - Scene

final class SnowScene: SKScene {
    var flakes: [Flake] = []
    var pool: [Flake] = []
    var piles: [Int: Pile] = [:]                 // window number -> snow on top of it
    var lastRect: [Int: CGRect] = [:]
    var order: [(id: Int, rect: CGRect)] = []    // windows from front to back
    var ground: Pile?
    var tex: SKTexture?
    var lastT: TimeInterval = 0
    var pollAcc: CGFloat = 0
    var t: CGFloat = 0
    let myPID = getpid()
    let world = SKNode()
    lazy var dockTracker = DockTracker()   // created on first use: it asks for Accessibility permission
    var dockPile: Pile?
    var dockRect: CGRect?
    var dockAcc: CGFloat = 1
    var lastDockStatus = ""
    var balls: [Snowball] = []
    weak var activeBall: Snowball?
    var lastMouse = NSEvent.mouseLocation
    var ballTex: SKTexture?
    var dragBall: Snowball?
    var dragTarget = CGPoint.zero
    var dragOffset = CGPoint.zero
    var dragVel = CGVector.zero
    var speckTex: SKTexture?
    static let dockID = -2

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        tex = makeFlakeTexture()
        ballTex = makeSnowballTexture()
        speckTex = makeSpeckTexture()
        addChild(world)
        resetGround()
        for _ in 0..<Cfg.targetFlakes { spawnFlake(y: rnd(0, size.height)) }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard tex != nil else { return }
        resetGround()
    }

    func resetGround() {
        for b in balls where b.pile === ground { b.drop(vel: .zero) }
        ground?.remove()
        ground = Pile(minX: 0, topY: 0, width: size.width, maxH: Cfg.groundPileMax, parent: world)
    }

    func clearAll() {
        for p in piles.values { p.clear(); p.redraw() }
        dockPile?.clear()
        dockPile?.redraw()
        ground?.clear()
        ground?.redraw()
        for b in balls { b.node.removeFromParent() }
        balls.removeAll()
    }

    // MARK: Flake pool

    func obtain() -> Flake {
        let f = pool.popLast() ?? Flake(texture: tex!)
        world.addChild(f.node)
        flakes.append(f)
        return f
    }

    func recycle(at i: Int) {
        let f = flakes[i]
        f.node.removeFromParent()
        flakes.swapAt(i, flakes.count - 1)
        flakes.removeLast()
        pool.append(f)
    }

    func spawnFlake(y: CGFloat? = nil) {
        let f = obtain()
        let r = CGFloat.random(in: 0...1)
        let li = r < 0.40 ? 0 : (r < 0.68 ? 1 : 2)   // 40% far, 28% middle, 32% near
        let L = layers[li]
        f.inFront = !Cfg.pileOnWindows
            || (Cfg.flakesInFront && li == 0 && CGFloat.random(in: 0...1) < Cfg.inFrontFraction)
        f.isClump = false
        f.ignoreID = -1
        f.size = CGFloat.random(in: L.size)
        f.vel = CGVector(dx: 0, dy: -CGFloat.random(in: L.speed) * Cfg.fallSpeed)
        f.swayAmp = CGFloat.random(in: L.sway)
        f.swayFreq = rnd(0.6, 1.6)
        f.phase = rnd(0, 6.28)
        f.windFactor = L.wind
        f.node.alpha = CGFloat.random(in: L.alpha)
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = L.z
        f.node.position = CGPoint(x: rnd(-40, size.width + 40), y: y ?? size.height + rnd(2, 30))
    }

    func spawnClump(at p: CGPoint, vel: CGVector, sourceID: Int) {
        let f = obtain()
        f.isClump = true
        f.inFront = false
        f.size = rnd(2.5, 5)
        f.vel = vel
        f.ignoreID = sourceID
        f.ignoreUntil = t + 0.35
        f.node.alpha = 0.95
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = 6
        f.node.position = p
    }

    // Turn a pile into falling clumps; vel is the window's velocity, so faster drags fling snow farther
    func release(_ p: Pile, vel: CGVector, id: Int) {
        let fling = CGVector(dx: max(-900, min(900, vel.dx * 0.5)),
                             dy: max(-300, min(500, vel.dy * 0.4)))
        // Snowballs sitting on this surface get flung off too
        for b in balls where b.pile === p {
            b.drop(vel: CGVector(dx: fling.dx + rnd(-30, 30), dy: fling.dy + rnd(20, 80)))
        }
        let total = p.total
        guard total > 0.5 else { p.clear(); return }
        let budget = CGFloat(max(0, Cfg.maxClumps - flakes.count + Cfg.targetFlakes))
        let k = min(1, budget / max(1, total / 3.5))
        for c in 0..<p.count where p.h[c] > 0.6 {
            var amount = p.h[c] / 3.5 * k
            while amount > 0 {
                if amount < 1 && CGFloat.random(in: 0...1) > amount { break }
                spawnClump(at: CGPoint(x: p.colX(c) + rnd(-1.5, 1.5), y: p.topY + rnd(0, p.h[c])),
                           vel: CGVector(dx: fling.dx + rnd(-40, 40), dy: fling.dy + rnd(10, 80)),
                           sourceID: id)
                amount -= 1
            }
        }
        p.clear()
    }

    // MARK: Per-frame update

    override func update(_ currentTime: TimeInterval) {
        if lastT == 0 { lastT = currentTime }
        let dt = CGFloat(min(currentTime - lastT, 1.0 / 20.0))
        lastT = currentTime
        t += dt
        pollAcc += dt
        if Double(pollAcc) >= Cfg.pollInterval {
            pollWindows(dt: pollAcc)
            pollAcc = 0
        }
        stepFlakes(dt)
        updateMouseCapture()
        if let b = dragBall { stepDrag(b, dt) } else { updateRolling(dt, mouse: NSEvent.mouseLocation) }
        stepBalls(dt)
    }

    // MARK: Dragging & snowmen

    /// The overlay normally lets every click through. Only while the mouse is over a snowball (or dragging one)
    /// does it catch clicks, so you can grab the ball without clicking the window underneath.
    func updateMouseCapture() {
        guard let w = view?.window else { return }
        let capture = dragBall != nil || ballAt(NSEvent.mouseLocation) != nil
        if w.ignoresMouseEvents == capture { w.ignoresMouseEvents = !capture }
    }

    /// The visible, resting snowball under a point (top of a stack first)
    func ballAt(_ m: CGPoint) -> Snowball? {
        var best: Snowball?
        for b in balls where !b.falling && !b.node.isHidden {
            let dx = m.x - b.x, dy = m.y - b.y
            if dx * dx + dy * dy <= (b.r + 2) * (b.r + 2), best == nil || b.y > best!.y { best = b }
        }
        return best
    }

    func above(_ b: Snowball) -> Snowball? { balls.first { $0.below === b } }

    func base(of b: Snowball) -> Snowball {
        var x = b
        while let y = x.below { x = y }
        return x
    }

    /// Balls in a stack from the bottom up
    func stack(from base: Snowball) -> [Snowball] {
        var out = [base]
        while let a = above(out.last!), out.count < 10 { out.append(a) }
        return out
    }

    /// Where the last dropped ball was let go: no new ball starts here until the cursor moves away,
    /// so a ball that bursts under the cursor isn't rolled right back up from its own heap
    var noNewBallNear: CGPoint?

    override func mouseDown(with event: NSEvent) {
        let m = event.location(in: self)
        guard let b = ballAt(m) else { return }
        grab(b, at: m)
    }

    func grab(_ b: Snowball, at m: CGPoint) {
        // Anything stacked on top of the grabbed ball tumbles off
        var a = above(b)
        while let x = a {
            a = above(x)
            x.drop(vel: CGVector(dx: rnd(-50, 50), dy: rnd(40, 100)))
        }
        removeDecor(stackOf: b)
        b.pile = nil
        b.below = nil
        b.vx = 0
        b.dragging = true
        b.node.zPosition = 8                 // in front while dragging
        dragBall = b
        activeBall = nil
        dragOffset = CGPoint(x: b.x - m.x, y: b.y - m.y)
        dragTarget = m
        dragVel = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        dragTarget = event.location(in: self)
    }

    override func mouseUp(with event: NSEvent) {
        letGo(at: event.location(in: self))
    }

    func letGo(at m: CGPoint) {
        guard let b = dragBall else { return }
        dragBall = nil
        b.dragging = false
        if let target = stackTarget(for: b) {
            stack(b, on: target)
        } else {
            b.node.zPosition = 6.5
            noNewBallNear = m
            // Let go: it falls (with a bit of the throw) and lands on whatever is below
            b.drop(vel: CGVector(dx: max(-600, min(600, dragVel.dx * 0.5)),
                                 dy: max(-400, min(400, dragVel.dy * 0.5))))
        }
    }

    func stepDrag(_ b: Snowball, _ dt: CGFloat) {
        let target = CGPoint(x: dragTarget.x + dragOffset.x, y: dragTarget.y + dragOffset.y)
        if dt > 0 {
            let v = CGVector(dx: (target.x - b.x) / dt, dy: (target.y - b.y) / dt)
            dragVel = CGVector(dx: dragVel.dx * 0.7 + v.dx * 0.3, dy: dragVel.dy * 0.7 + v.dy * 0.3)
        }
        b.specks.zRotation -= (target.x - b.x) / b.r
        b.x = target.x
        b.y = target.y
        lastMouse = NSEvent.mouseLocation
    }

    /// Put b on top of target (a snowman once three are stacked)
    func stack(_ b: Snowball, on target: Snowball) {
        b.falling = false
        b.pile = nil
        b.below = target
        b.vel = .zero
        b.vx = 0
        let st = stack(from: base(of: b))
        for (i, x) in st.enumerated() { x.node.zPosition = 6.5 + CGFloat(i) * 0.3 }
        if st.count == 3 { makeSnowman(st) }
    }

    /// A ball dropped just above another ball (that isn't already a full snowman) gets stacked on it
    func stackTarget(for b: Snowball) -> Snowball? {
        var best: Snowball?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for c in balls where c !== b && !c.falling && !c.dragging && !c.node.isHidden {
            guard above(c) == nil, stack(from: base(of: c)).count < 3 else { continue }
            let dx = abs(b.x - c.x), dy = b.y - c.y
            guard dx < c.r * 0.9 + b.r * 0.3, dy > 0, dy < c.r + b.r + 30 else { continue }
            if dx < bestDist { best = c; bestDist = dx }
        }
        return best
    }

    func removeDecor(stackOf b: Snowball) {
        for x in stack(from: base(of: b)) {
            x.decor?.removeFromParent()
            x.decor = nil
        }
    }

    /// Three stacked balls become a snowman: face and scarf on the head, buttons and stick arms on the body
    func makeSnowman(_ st: [Snowball]) {
        let body = st[1], head = st[2]
        removeDecor(stackOf: head)
        let R = head.r

        let h = SKNode()
        h.zPosition = 0.5
        for sx in [-1.0, 1.0] as [CGFloat] {
            let eye = SKShapeNode(circleOfRadius: max(1, R * 0.09))
            eye.fillColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            eye.strokeColor = .clear
            eye.position = CGPoint(x: sx * R * 0.3, y: R * 0.22)
            h.addChild(eye)
        }
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: R * 0.02, y: R * 0.06))
        nose.addLine(to: CGPoint(x: R * 0.75, y: -R * 0.04))
        nose.addLine(to: CGPoint(x: R * 0.02, y: -R * 0.12))
        nose.closeSubpath()
        let carrot = SKShapeNode(path: nose)
        carrot.fillColor = NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.13, alpha: 1)
        carrot.strokeColor = .clear
        h.addChild(carrot)
        for k in 0..<5 {
            let a = CGFloat.pi * (1.2 + 0.15 * CGFloat(k))
            let dot = SKShapeNode(circleOfRadius: max(0.7, R * 0.05))
            dot.fillColor = NSColor(calibratedWhite: 0.1, alpha: 1)
            dot.strokeColor = .clear
            dot.position = CGPoint(x: cos(a) * R * 0.42, y: sin(a) * R * 0.42 - R * 0.05)
            h.addChild(dot)
        }
        let red = NSColor(calibratedRed: 0.82, green: 0.16, blue: 0.18, alpha: 1)
        let scarf = SKShapeNode(rect: CGRect(x: -R * 0.85, y: -R * 0.98, width: R * 1.7, height: R * 0.3),
                                cornerRadius: R * 0.12)
        scarf.fillColor = red
        scarf.strokeColor = .clear
        h.addChild(scarf)
        let tail = SKShapeNode(rect: CGRect(x: R * 0.3, y: -R * 1.55, width: R * 0.28, height: R * 0.7),
                               cornerRadius: R * 0.08)
        tail.fillColor = red
        tail.strokeColor = .clear
        tail.zRotation = -0.15
        h.addChild(tail)
        head.node.addChild(h)
        head.decor = h

        let B = body.r
        let bd = SKNode()
        bd.zPosition = 0.5
        for k in 0..<3 {
            let btn = SKShapeNode(circleOfRadius: max(0.8, B * 0.07))
            btn.fillColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            btn.strokeColor = .clear
            btn.position = CGPoint(x: 0, y: B * (0.35 - 0.33 * CGFloat(k)))
            bd.addChild(btn)
        }
        let brown = NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.16, alpha: 1)
        for sx in [-1.0, 1.0] as [CGFloat] {
            let arm = CGMutablePath()
            arm.move(to: CGPoint(x: sx * B * 0.85, y: B * 0.15))
            arm.addLine(to: CGPoint(x: sx * B * 1.75, y: B * 0.65))
            arm.move(to: CGPoint(x: sx * B * 1.4, y: B * 0.45))
            arm.addLine(to: CGPoint(x: sx * B * 1.55, y: B * 0.85))
            let stick = SKShapeNode(path: arm)
            stick.strokeColor = brown
            stick.lineWidth = max(1.2, B * 0.09)
            stick.lineCap = .round
            bd.addChild(stick)
        }
        body.node.addChild(bd)
        body.decor = bd
    }

    // MARK: Snowballs

    /// Is the mouse inside the snow band of this pile (a bit below the edge up to a bit above the snow)?
    func mouseOver(_ p: Pile, _ m: CGPoint) -> Bool {
        guard let c = p.col(at: m.x), !p.occ[c] else { return false }
        return m.y >= p.topY - 6 && m.y <= p.topY + p.h[c] + 14
    }

    /// Which snow surface is the mouse hovering over? Dock first, then windows front to back, then the ground.
    func surfaceUnderMouse(_ m: CGPoint) -> Pile? {
        // Hovering over a snowball counts as hovering over the snow it sits on. Without this, a big ball
        // stops rolling as soon as the cursor rises above the thin snow band, which makes pushing jerky.
        for b in balls where !b.falling && !b.dragging && !b.node.isHidden && b.below == nil {
            guard let p = b.pile, abs(m.x - b.x) < b.r + 8 else { continue }
            if m.y >= p.topY - 6 && m.y <= b.y + b.r + 8 { return p }
        }
        if let d = dockPile, mouseOver(d, m) { return d }
        if let dr = dockRect, dr.contains(m) { return nil }
        for item in order {
            if let p = piles[item.id], mouseOver(p, m) { return p }
            if item.rect.contains(m) { return nil }      // over a window's content
        }
        if let g = ground, mouseOver(g, m) { return g }
        return nil
    }

    /// The ball the mouse is rolling this frame; it follows the mouse instead of coasting
    weak var drivenBall: Snowball?

    func updateRolling(_ dt: CGFloat, mouse m: CGPoint) {
        let dx = m.x - lastMouse.x
        lastMouse = m
        drivenBall = nil
        // The ball under the mouse only rolls while the mouse moves: it stops when the mouse stops
        guard let p = surfaceUnderMouse(m) else { activeBall?.vx = 0; activeBall = nil; noNewBallNear = nil; return }
        if let q = noNewBallNear, abs(m.x - q.x) > 60 { noNewBallNear = nil }
        guard abs(dx) > 0.2 else { activeBall?.vx = 0; return }

        // Keep rolling the current ball, pick up a resting one under the mouse, or start a new one
        if let b = activeBall, b.pile === p, above(b) == nil, abs(b.x - (m.x - dx)) < b.r + 25 {   // ball was at the previous mouse x
            // keep it
        } else if let b = balls.first(where: { !$0.falling && $0.pile === p && abs($0.x - m.x) < $0.r + 10 }) {
            guard above(b) == nil else { activeBall = nil; return }   // don't roll the bottom of a snowman
            activeBall = b
        } else if noNewBallNear == nil, let c = p.col(at: m.x), p.h[c] > 1.5 {
            let b = Snowball(body: ballTex!, specks: speckTex!)
            b.x = m.x
            b.pile = p
            b.y = restY(b, on: p)
            b.layout()
            world.addChild(b.node)
            balls.append(b)
            activeBall = b
            trimBalls()
        } else {
            activeBall = nil
            return
        }
        guard let b = activeBall else { return }

        // Move the ball to the mouse, staying on the surface. Its speed is only used to shove other balls.
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        let newX = lo < hi ? min(max(m.x, lo), hi) : b.x
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        if dt > 0 {
            let v = max(-Cfg.maxRollSpeed, min(Cfg.maxRollSpeed, moved / dt))
            b.vx = b.vx * 0.5 + v * 0.5
        }
        drivenBall = b
        let oldX = b.x
        roll(b, on: p, to: newX)
        push(from: b, oldX: oldX, dir: moved > 0 ? 1 : -1, on: p)
    }

    /// Height of a ball's center when it rests on the snow: it sits on the highest snow under it,
    /// sunk in a little (deeper snow = more sink), and never below the bare surface.
    func restY(_ b: Snowball, on p: Pile) -> CGFloat {
        let bare = p.topY + b.r - 1.5
        guard p.count > 0 else { return bare }
        let c0 = max(0, Int((b.x - b.r - p.minX) / Cfg.colW))
        let c1 = min(p.count - 1, Int((b.x + b.r - p.minX) / Cfg.colW))
        guard c0 <= c1 else { return bare }
        var top = bare
        for c in c0...c1 where !p.occ[c] {
            let dx = p.colX(c) - b.x
            let s = b.r * b.r - dx * dx
            if s > 0 { top = max(top, p.topY + p.h[c] + s.squareRoot()) }
        }
        let depth = p.surfaceAt(b.x) - p.topY
        let sink = min(b.r * 0.3, depth * 0.5)
        return max(bare, top - sink)
    }

    /// Horizontal distance between two balls resting side by side when they touch. A small ball
    /// sits lower than a big one, so it tucks in a little under the big ball's curve.
    func touchDist(_ a: Snowball, _ b: Snowball) -> CGFloat { 2 * (a.r * b.r).squareRoot() }

    /// Roll a ball to newX. The front of the ball picks up snow and the ball grows; a full-size ball
    /// plows the snow ahead of it into a ridge instead. The snow under the ball is packed down,
    /// so it leaves a track.
    func roll(_ b: Snowball, on p: Pile, to newX: CGFloat) {
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        let dir: CGFloat = moved > 0 ? 1 : -1
        let frac = min(0.6, 0.6 * abs(moved) / (1.6 * b.r))
        var scooped: CGFloat = 0

        // The leading half of the ball sweeps up snow
        let from = dir > 0 ? b.x : newX - b.r * 0.8
        let to = dir > 0 ? newX + b.r * 0.8 : b.x
        if let c0 = p.col(at: max(from, p.minX)), let c1 = p.col(at: min(to, p.minX + p.width - 0.1)), c0 <= c1 {
            for c in c0...c1 where !p.occ[c] {
                let take = p.h[c] * frac
                p.h[c] -= take
                scooped += take
            }
            p.dirty = true
        }
        // Behind the center the snow gets squashed: packed snow takes less room
        let packFrom = dir > 0 ? newX - b.r * 0.6 : newX
        let packTo = dir > 0 ? newX : newX + b.r * 0.6
        if let c0 = p.col(at: max(packFrom, p.minX)), let c1 = p.col(at: min(packTo, p.minX + p.width - 0.1)), c0 <= c1 {
            for c in c0...c1 where !p.occ[c] { p.h[c] *= 1 - 0.35 * frac }
        }

        // Grow by the snow picked up (ball area grows by the snow area), up to the max size
        let room = max(0, CGFloat.pi * (Cfg.ballMaxRadius * Cfg.ballMaxRadius - b.r * b.r) / (Cfg.colW * 0.8))
        let keep = min(scooped, room)
        if keep > 0 {
            let area = CGFloat.pi * b.r * b.r + keep * Cfg.colW * 0.8
            b.r = min(Cfg.ballMaxRadius, (area / .pi).squareRoot())
        }
        // What the ball can't hold is shoved forward
        let rest = scooped - keep
        if rest > 0.01 { plow(rest, on: p, at: newX + dir * (b.r + Cfg.colW), dir: dir) }

        b.x = newX
        b.specks.zRotation -= moved / b.r     // roll
    }

    /// Pile snow into a ridge just ahead of a ball; whatever doesn't fit sprays up as powder
    func plow(_ amount: CGFloat, on p: Pile, at x: CGFloat, dir: CGFloat) {
        guard let c = p.col(at: x) else { return }
        var spill: CGFloat = 0
        for (k, w) in [(0, 0.5), (1, 0.3), (2, 0.2)] as [(Int, CGFloat)] {
            spill += p.deposit(at: c + k * Int(dir), amount * w)
        }
        if spill > 1 { spray(at: CGPoint(x: x, y: p.surfaceAt(x)), dir: dir, speed: 160, count: min(4, Int(spill / 1.5) + 1)) }
    }

    /// A few clumps of powder kicked up and forward
    func spray(at pt: CGPoint, dir: CGFloat, speed: CGFloat, count: Int) {
        for _ in 0..<count where flakes.count < Cfg.maxClumps + Cfg.targetFlakes {
            spawnClump(at: CGPoint(x: pt.x + rnd(-2, 2), y: pt.y + rnd(0, 3)),
                       vel: CGVector(dx: dir * speed * rnd(0.3, 0.9), dy: rnd(70, 190)),
                       sourceID: -3)
        }
    }

    /// The ball the mouse moves pushes any ball it touches in front of it; that ball can push the next
    /// one, and so on. Pushed balls take on the pusher's speed, so they roll on a little after a shove.
    /// A ball pushed past the end of a Dock or window pile falls off.
    func push(from b: Snowball, oldX: CGFloat, dir: CGFloat, on p: Pile) {
        // Look for balls ahead of where the pusher *was*: after a fast mouse move it may already have
        // jumped past a ball, and that ball must still be pushed instead of being passed through.
        let ahead = balls
            .filter { $0 !== b && !$0.falling && !$0.dragging && $0.pile === p && ($0.x - oldX) * dir > 0 }
            .sorted { abs($0.x - oldX) < abs($1.x - oldX) }
        var pusher = b
        for o in ahead {
            let need = pusher.x + dir * touchDist(pusher, o)  // where o must be to just touch the pusher
            guard (need - o.x) * dir > 0 else { break }       // not touching: the chain stops here
            if above(o) != nil {                               // a snowman doesn't budge: the pusher stops at it
                pusher.x = o.x - dir * touchDist(pusher, o)
                pusher.vx = 0
                break
            }
            let lo = p.minX + o.r, hi = p.minX + p.width - o.r
            if need < lo || need > hi {
                if p === ground {
                    o.x = min(max(need, lo), hi)               // the screen edge stops it
                    o.vx = 0
                } else {
                    o.x = need
                    o.drop(vel: CGVector(dx: dir * max(140, abs(pusher.vx)), dy: 40))   // pushed off the edge
                }
            } else {
                roll(o, on: p, to: need)
                // A pushed ball moves along with the pusher and rolls on a little after the shove
                if (o.vx - pusher.vx) * dir < 0 { o.vx = pusher.vx }
            }
            pusher = o
        }
    }

    /// One frame of rolling for a ball nobody is moving: slopes speed it up, snow slows it down
    func coast(_ b: Snowball, on p: Pile, _ dt: CGFloat) {
        if above(b) != nil { b.vx = 0; return }        // the base of a snowman stays put
        // Gravity along the slope; 5/7 because a solid ball spends some energy spinning
        let hl = p.surfaceAt(b.x - b.r * 0.6), hr = p.surfaceAt(b.x + b.r * 0.6)
        let slope = (hr - hl) / (1.2 * b.r)
        let ga = -Cfg.gravity * (5.0 / 7.0) * slope
        // Rolling resistance, plus more when the ball has to push through snow piled in front of it
        let dirv: CGFloat = b.vx != 0 ? (b.vx > 0 ? 1 : -1) : (ga > 0 ? 1 : -1)
        let ahead = max(0, p.surfaceAt(b.x + dirv * b.r * 0.9) - (b.y - b.r * 0.5))
        let resist = Cfg.gravity * (Cfg.rollFriction + Cfg.plowDrag * min(1.5, ahead / b.r))
        if abs(b.vx) < 3 && abs(ga) < resist {
            b.vx = 0                                    // resting: too flat to start rolling
            return
        }
        b.vx += ga * dt
        let f = resist * dt
        b.vx = abs(b.vx) <= f ? 0 : b.vx - (b.vx > 0 ? f : -f)
        b.vx *= max(0, 1 - Cfg.rollDrag * dt)
        b.vx = max(-Cfg.maxRollSpeed, min(Cfg.maxRollSpeed, b.vx))
        guard b.vx != 0 else { return }

        var newX = b.x + b.vx * dt
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        if newX < lo || newX > hi {
            if p === ground {                           // bounce softly off the screen edge
                newX = min(max(newX, lo), hi)
                b.vx = -b.vx * Cfg.ballBounce
            } else {                                    // rolls off the end of the Dock or a window
                b.x = newX
                b.drop(vel: CGVector(dx: b.vx, dy: 30))
                return
            }
        }
        roll(b, on: p, to: newX)
        if abs(b.vx) > 260, CGFloat.random(in: 0...1) < dt * abs(b.vx) / 60 {
            spray(at: CGPoint(x: b.x + (b.vx > 0 ? 1 : -1) * b.r * 0.8, y: b.y - b.r * 0.6), dir: b.vx > 0 ? 1 : -1,
                  speed: abs(b.vx) * 0.4, count: 1)
        }
    }

    /// Resting and rolling balls on the same surface bump into each other: they never overlap, and a
    /// collision trades speed by weight. Snowman bases and the ball under the mouse act as immovable.
    func collideBalls() {
        var groups: [ObjectIdentifier: [Snowball]] = [:]
        for b in balls where !b.falling && !b.dragging && b.below == nil {
            guard let p = b.pile else { continue }
            groups[ObjectIdentifier(p), default: []].append(b)
        }
        for (_, group) in groups where group.count > 1 {
            let row = group.sorted { $0.x < $1.x }
            for _ in 0..<2 {
                for i in 0..<(row.count - 1) {
                    let a = row[i], b = row[i + 1]
                    let overlap = touchDist(a, b) - (b.x - a.x)
                    guard overlap > 0 else { continue }
                    let aFixed = a === drivenBall || above(a) != nil
                    let bFixed = b === drivenBall || above(b) != nil
                    if aFixed && bFixed { continue }
                    let wa: CGFloat = aFixed ? 0 : (bFixed ? 1 : b.mass / (a.mass + b.mass))
                    a.x -= overlap * wa
                    b.x += overlap * (1 - wa)
                    let closing = a.vx - b.vx
                    guard closing > 0 else { continue }   // already moving apart
                    let e = Cfg.ballBounce
                    if aFixed {
                        b.vx = a.vx + e * closing
                    } else if bFixed {
                        a.vx = b.vx - e * closing
                    } else {
                        let p = a.mass * a.vx + b.mass * b.vx, m = a.mass + b.mass
                        a.vx = (p - b.mass * e * closing) / m
                        b.vx = (p + a.mass * e * closing) / m
                    }
                }
            }
        }
    }

    func trimBalls() {
        while balls.count > Cfg.maxBalls,
              let i = balls.firstIndex(where: { !$0.falling && !$0.dragging && $0.decor == nil && $0 !== activeBall }) {
            balls[i].node.removeFromParent()
            balls.remove(at: i)
        }
    }

    func stepBalls(_ dt: CGFloat) {
        var i = balls.count - 1
        while i >= 0 {
            let b = balls[i]
            var gone = false
            if b.crushed {
                gone = true
            } else if b.falling {
                if b.decor != nil { b.decor?.removeFromParent(); b.decor = nil }
                b.node.zPosition = 6.5
                let prevBottom = b.y - b.r
                b.vel.dy -= Cfg.gravity * dt
                b.x += b.vel.dx * dt
                b.y += b.vel.dy * dt
                b.specks.zRotation -= b.vel.dx * dt / b.r
                if hitBalls(b) {
                    gone = true                      // burst against a bigger ball
                } else if !b.falling {
                    // landed on top of a ball and stacked there
                } else if b.vel.dy < 0, let p = landingSurface(x: b.x, from: prevBottom, to: b.y - b.r) {
                    gone = impact(b, on: p)          // lands whole, loses a chunk, or bursts, by how hard it hits
                } else if b.y < -b.r * 2 || b.x < -100 || b.x > size.width + 100 {
                    gone = true
                }
            } else if b.dragging {
                // position is set by stepDrag
            } else if let under = b.below {
                if under.falling || under.dragging {
                    b.drop(vel: CGVector(dx: under.vel.dx + rnd(-40, 40), dy: max(under.vel.dy, 0) + rnd(30, 80)))
                } else {
                    b.x = under.x
                    b.y = under.y + under.r + b.r * 0.82   // sits slightly sunk into the ball below
                    b.node.isHidden = under.node.isHidden
                }
            } else if let p = b.pile {
                if b !== drivenBall { coast(b, on: p, dt) }
                if b.falling { i -= 1; continue }  // rolled off the end; falls from the next frame
                if let c = p.col(at: b.x) {
                    b.node.isHidden = p.occ[c]     // hidden behind a window in front
                } else {
                    b.node.isHidden = true
                }
                // Ride on top of the snow; ease toward it so bumps in the snow don't make it jitter
                let target = restY(b, on: p)
                b.y = abs(target - b.y) > b.r ? target : b.y + (target - b.y) * min(1, dt * 25)
            } else {
                b.drop(vel: .zero)                 // lost its support (e.g. the ball below was removed)
            }
            if gone {
                b.node.removeFromParent()
                balls.remove(at: i)
            } else {
                b.layout()
            }
            i -= 1
        }
        // Balls grow and move above, so settle contacts last, after everything has moved this frame
        collideBalls()
        for b in balls where !b.falling && !b.dragging { b.layout() }
    }

    /// First surface a falling ball hits between two heights: the Dock, then window tops (front to back),
    /// then the bottom of the screen. Returns nil if it hits nothing this frame.
    func landingSurface(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Pile? {
        func crosses(_ p: Pile) -> Bool {
            guard let c = p.col(at: x), !p.occ[c] else { return false }
            let s = p.surface(c)
            return top >= s && bottom < s
        }
        if let d = dockPile, crosses(d) { return d }
        for item in order {
            if let p = piles[item.id], crosses(p) { return p }
        }
        // The ground catches everything that reaches the bottom, even where a window covers it
        if let g = ground, let c = g.col(at: x), bottom < g.surface(c) { return g }
        return nil
    }

    /// A falling ball hits a surface. Soft landings keep it whole, harder ones break off a share of its snow
    /// (the share grows with impact energy), and hard ones burst it. Returns true if the ball is gone.
    ///
    /// Only the downward speed counts: a sideways throw keeps rolling. Fresh snow under the ball cushions the
    /// hit (bare ground, the Dock or a packed track hardly does). A big ball is heavy for its strength
    /// (weight grows with r³, strength with r²), so it breaks from a lower drop than a small one.
    func impact(_ b: Snowball, on p: Pile) -> Bool {
        let fall = max(0, -b.vel.dy)
        let depth = p.col(at: b.x).map { p.occ[$0] ? 0 : p.h[$0] } ?? 0
        let v = fall * (1 - 0.5 * min(1, depth / Cfg.ballCushionDepth))
        let k = strength(b.r)
        let lo = Cfg.ballCrackSpeed * k, hi = Cfg.ballBurstSpeed * k
        let broken = v <= lo ? 0 : min(1, (v * v - lo * lo) / (hi * hi - lo * lo))
        let left = b.r * (1 - broken).squareRoot()          // what's left keeps (1 - broken) of the ball's area
        if broken >= 1 || left < Cfg.ballStartRadius + 1 {
            splat(b, on: p)                                  // bursts into a heap of snow
            return true
        }
        dent(p, at: b.x, r: b.r, depth: min(0.6, 0.8 * fall / Cfg.ballBurstSpeed))
        if broken > 0 {
            splat(b, on: p, share: broken)
            b.r = left
        }
        land(b, on: p)
        return false
    }

    /// How much harder than a 12 px ball this ball is to break (speed multiplier): small balls are tougher
    func strength(_ r: CGFloat) -> CGFloat { (Cfg.ballStartRadius * 4 / max(r, 1)).squareRoot() }

    /// A landing ball sinks into the snow: a share of the snow under it is pushed out into a rim on both
    /// sides, and a little powder flies up
    func dent(_ p: Pile, at x: CGFloat, r: CGFloat, depth share: CGFloat) {
        guard share > 0.02, let c0 = p.col(at: x - r * 0.7), let c1 = p.col(at: x + r * 0.7), c0 <= c1 else { return }
        var moved: CGFloat = 0
        for c in c0...c1 where !p.occ[c] {
            let take = p.h[c] * share
            p.h[c] -= take
            moved += take
        }
        guard moved > 0.01 else { return }
        p.dirty = true
        let w = max(1, Int(r / Cfg.colW))                  // rim width in columns, each side
        var spill: CGFloat = 0
        for k in 1...w {
            spill += p.deposit(at: c0 - k, moved / CGFloat(2 * w))
            spill += p.deposit(at: c1 + k, moved / CGFloat(2 * w))
        }
        let n = min(6, Int(moved / 4) + Int(spill / 2))
        for i in 0..<n {
            let dir: CGFloat = i % 2 == 0 ? 1 : -1
            spawnClump(at: CGPoint(x: x + dir * r * rnd(0.6, 1), y: p.surfaceAt(x) + 1),
                       vel: CGVector(dx: dir * rnd(40, 120), dy: rnd(60, 160)), sourceID: -3)
        }
    }

    /// A falling ball that runs into a resting one. A hard hit crushes the smaller of the two (how hard
    /// depends on the bigger, heavier one); a gentle, centered drop stacks it on top; anything else
    /// glances off and nudges the ball it hit. Returns true if the falling ball itself is gone.
    func hitBalls(_ b: Snowball) -> Bool {
        for o in balls where o !== b && !o.falling && !o.dragging && !o.crushed && !o.node.isHidden {
            let dx = b.x - o.x, dy = b.y - o.y
            let d = (dx * dx + dy * dy).squareRoot(), minD = b.r + o.r
            guard d < minD, d > 0.01 else { continue }
            let fall = max(0, -b.vel.dy)
            let support = base(of: o).pile ?? ground
            if fall > Cfg.ballBurstSpeed * strength(max(b.r, o.r)), let support {
                if b.r <= o.r {
                    splat(b, on: support)
                    return true
                }
                var a = above(o)                          // whatever sat on it tumbles off
                while let x = a {
                    a = above(x)
                    x.drop(vel: CGVector(dx: rnd(-60, 60), dy: rnd(40, 100)))
                }
                removeDecor(stackOf: o)
                splat(o, on: support)
                o.crushed = true
                o.node.isHidden = true
                o.pile = nil
                o.below = nil
                b.vel.dy *= 0.5                           // crushing it took some of the fall out of the ball
                continue
            }
            if dy > 0, abs(dx) < o.r * 0.5, fall < Cfg.ballCrackSpeed * 0.6, above(o) == nil,
               o.decor == nil, stack(from: base(of: o)).count < 3 {
                stack(b, on: o)
                return false
            }
            // Glance off: move out of the other ball and bounce a little along the contact direction
            let nx = dx / d, ny = dy / d
            b.x = o.x + nx * minD
            b.y = o.y + ny * minD
            let vn = b.vel.dx * nx + b.vel.dy * ny
            if vn < 0 {
                b.vel.dx -= (1 + Cfg.ballBounce) * vn * nx
                b.vel.dy -= (1 + Cfg.ballBounce) * vn * ny
                if o.pile != nil, o.below == nil, above(o) == nil {
                    o.vx += nx * vn * b.mass / (b.mass + o.mass)   // shoved away from the falling ball
                }
            }
            if abs(nx) < 0.25 { b.vel.dx += (nx >= 0 ? 1 : -1) * 40 }   // don't balance on top: roll off
        }
        return false
    }

    /// A falling ball bursts where it lands: its snow (or `share` of it, for a partial break) becomes a mound
    /// on that surface, plus a puff of powder
    func splat(_ b: Snowball, on p: Pile, share: CGFloat = 1) {
        if let c0 = p.col(at: b.x) {
            let snow = CGFloat.pi * b.r * b.r * 0.7 * share / Cfg.colW     // ball area -> total column height
            let half = max(2, Int(b.r * 1.4 / Cfg.colW))
            var sum: CGFloat = 0
            for o in -half...half { sum += 1 - abs(CGFloat(o)) / CGFloat(half + 1) }
            for o in -half...half {
                let i = c0 + o
                guard i >= 0, i < p.count, !p.occ[i] else { continue }
                let w = (1 - abs(CGFloat(o)) / CGFloat(half + 1)) / sum
                p.h[i] = min(p.caps[i], p.h[i] + snow * w)
            }
            p.dirty = true
        }
        for _ in 0..<Int(CGFloat(min(14, Int(b.r * 0.6) + 2)) * share) {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y - b.r * 0.5 + rnd(0, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.2 + rnd(-90, 90), dy: rnd(60, 180)),
                       sourceID: -3)
        }
    }

    /// A falling ball comes to rest on a surface and can be rolled again from there. It keeps most of
    /// its sideways speed and rolls on.
    func land(_ b: Snowball, on p: Pile) {
        b.falling = false
        b.vx = max(-Cfg.maxRollSpeed, min(Cfg.maxRollSpeed, b.vel.dx * Cfg.ballSideKeep))
        b.vel = .zero
        b.pile = p
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        if lo < hi { b.x = min(max(b.x, lo), hi) }
        b.y = restY(b, on: p)
    }

    /// A falling snowball bursts into loose snow when it hits the ground
    func poof(_ b: Snowball) {
        let n = min(40, Int(b.r * 1.6))
        for _ in 0..<n {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y + rnd(-b.r * 0.5, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.3 + rnd(-90, 90), dy: rnd(40, 170)),
                       sourceID: -3)
        }
    }

    // Read all window frames (macOS origin is top-left, SpriteKit is bottom-left, so flip y)
    func pollWindows(dt: CGFloat) {
        let H = size.height
        var newOrder: [(id: Int, rect: CGRect)] = []
        if Cfg.pileOnWindows, let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in info {
                guard let layerN = w[kCGWindowLayer as String] as? NSNumber, layerN.intValue == 0,
                      let pidN = w[kCGWindowOwnerPID as String] as? NSNumber, pidN.int32Value != myPID,
                      let numN = w[kCGWindowNumber as String] as? NSNumber,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                if alpha < 0.05 || b.width < 80 || b.height < 40 { continue }
                newOrder.append((id: numN.intValue,
                                 rect: CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height)))
            }
        }

        // Closed / minimized windows: their snow just falls
        let alive = Set(newOrder.map { $0.id })
        for (id, pile) in piles where !alive.contains(id) {
            release(pile, vel: .zero, id: id)
            pile.remove()
            piles[id] = nil
            lastRect[id] = nil
        }

        for item in newOrder {
            let id = item.id, r = item.rect
            if let pile = piles[id], let old = lastRect[id] {
                if abs(old.width - r.width) > 0.5 {
                    // Width changed: drop the snow and start a new pile
                    release(pile, vel: .zero, id: id)
                    pile.remove()
                    piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
                } else if abs(old.minX - r.minX) > 0.3 || abs(old.maxY - r.maxY) > 0.3 {
                    // Window dragged: fling the snow off
                    let v = CGVector(dx: (r.minX - old.minX) / dt, dy: (r.maxY - old.maxY) / dt)
                    pile.minX = r.minX
                    pile.topY = r.maxY
                    release(pile, vel: v, id: id)
                }
            } else {
                piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
            }
            lastRect[id] = r
        }
        order = newOrder

        // The Dock rarely changes; checking every 0.5 s is enough
        dockAcc += dt
        if dockAcc >= 0.5 {
            dockAcc = 0
            updateDock()
        }

        computeOcclusion()
        for p in piles.values { p.redraw() }
        dockPile?.redraw()
        ground?.redraw()
    }

    func updateDock() {
        var r: CGRect? = nil
        var status: String
        if let f = dockTracker.frame() {
            var s = CGRect(x: f.minX - Cfg.dockPad, y: size.height - f.maxY,
                           width: f.width + 2 * Cfg.dockPad, height: f.height)
            // The AX frame can reach a bit above the visible Dock shelf. When the Dock is always
            // shown, the space macOS reserves for it (bottom of visibleFrame) is a better top edge.
            if let screen = NSScreen.screens.first {
                let reserved = screen.visibleFrame.minY - screen.frame.minY
                if reserved > 10 && reserved < s.maxY { s.size.height = reserved - s.minY }
            }
            // Only handle a Dock that sits at the bottom of the screen and is currently on screen.
            // With auto-hide, a hidden Dock is reported below the screen edge, so it fails this check.
            if s.width > s.height && s.minY < 40 && s.maxY > 8 {
                r = s
                status = "found at x=\(Int(s.minX)) width=\(Int(s.width)) top=\(Int(s.maxY)) (AX top \(Int(size.height - f.minY)), screen \(Int(size.width))x\(Int(size.height)))"
            } else {
                status = "ignored (not at bottom or hidden), AX frame = \(f)"
            }
        } else {
            status = "not found: \(dockTracker.lastError)"
        }
        // Log only when the status changes, so the terminal doesn't get flooded
        let key = status.components(separatedBy: " at ").first ?? status
        if key != lastDockStatus {
            print("❄︎ Dock " + status)
            lastDockStatus = key
        }
        if let old = dockRect, let r = r,
           abs(old.minX - r.minX) < 0.5, abs(old.width - r.width) < 0.5, abs(old.maxY - r.maxY) < 0.5 {
            return
        }
        // Dock resized (new app opened, magnification): drop its snow and start again
        if let p = dockPile {
            release(p, vel: .zero, id: SnowScene.dockID)
            p.remove()
            dockPile = nil
        }
        dockRect = r
        if let r = r {
            dockPile = Pile(minX: r.minX, topY: r.maxY + Cfg.dockTopOffset, width: r.width,
                            maxH: Cfg.dockPileMax, parent: world)
        }
    }

    // Parts of a window top hidden behind a front window get no snow and aren't drawn
    func computeOcclusion() {
        for (i, item) in order.enumerated() {
            guard let p = piles[item.id] else { continue }
            for c in 0..<p.count {
                let pt = CGPoint(x: p.colX(c), y: p.topY + 1)
                var o = pt.x < 0 || pt.x > size.width || pt.y > size.height
                if !o {
                    for j in 0..<i where order[j].rect.contains(pt) { o = true; break }
                }
                if o != p.occ[c] {
                    p.occ[c] = o
                    if o { p.h[c] = 0 }
                    p.dirty = true
                }
            }
        }
        if let g = ground {
            for c in 0..<g.count {
                let pt = CGPoint(x: g.colX(c), y: 1)
                var o = false
                for item in order where item.rect.contains(pt) { o = true; break }
                if o != g.occ[c] {
                    g.occ[c] = o
                    if o { g.h[c] = 0 }
                    g.dirty = true
                }
            }
        }
    }

    func stepFlakes(_ dt: CGFloat) {
        // A few sines at different frequencies add up to gusty wind
        let wind = 14 * sin(t * 0.11) + 9 * sin(t * 0.37 + 1.3) + 6 * sin(t * 0.9 + 0.4)
        var normal = 0
        var i = flakes.count - 1
        while i >= 0 {
            let f = flakes[i]
            var p = f.node.position
            let prevY = p.y

            if f.isClump {
                f.vel.dy -= Cfg.gravity * dt
                f.vel.dx *= max(0, 1 - 1.2 * dt)
                p.x += f.vel.dx * dt
                p.y += f.vel.dy * dt
            } else {
                let sway = sin(t * f.swayFreq + f.phase) * f.swayAmp
                p.x += (wind * f.windFactor + sway) * dt
                p.y += f.vel.dy * dt
                if p.x < -40 { p.x += size.width + 80 } else if p.x > size.width + 40 { p.x -= size.width + 80 }
            }

            var gone = false
            if p.y < prevY {
                // The Dock is always in front of every window, so check it first
                if let d = dockPile, let c = d.col(at: p.x),
                   !(f.isClump && f.ignoreID == SnowScene.dockID && t < f.ignoreUntil) {
                    let s = d.surface(c)
                    if prevY >= s && p.y < s {
                        d.add(at: c, amount: (f.isClump ? 1.6 : f.size * 0.16) * Cfg.dockGain)
                        gone = true
                    }
                }
                // Then check window tops, front to back
                if !gone && !f.inFront { for item in order {
                    guard let pile = piles[item.id] else { continue }
                    if f.isClump && item.id == f.ignoreID && t < f.ignoreUntil { continue }
                    guard let c = pile.col(at: p.x), !pile.occ[c] else { continue }
                    let s = pile.surface(c)
                    if prevY >= s && p.y < s {
                        pile.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.16)
                        gone = true
                        break
                    }
                } }
                // Finally the bottom of the screen
                if !gone, let g = ground, let c = g.col(at: p.x), p.y < g.surface(c) {
                    if !g.occ[c] { g.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.12) }
                    gone = true
                }
            }
            if !gone {
                // Flakes that fall "behind" a window disappear
                if !f.inFront {
                    for item in order where item.rect.contains(p) { gone = true; break }
                }
                if p.y < -20 { gone = true }
                if f.isClump && (p.x < -80 || p.x > size.width + 80) { gone = true }
            }

            if gone {
                recycle(at: i)
            } else {
                f.node.position = p
                if !f.isClump { normal += 1 }
            }
            i -= 1
        }

        // Top up flakes (max 6 per frame so they don't appear in a row)
        let deficit = min(6, Cfg.targetFlakes - normal)
        if deficit > 0 { for _ in 0..<deficit { spawnFlake() } }
    }
}

// MARK: - Transparent full-screen window + menu bar icon

/// Lets the very first click reach the scene even though this app is never the active app
final class OverlaySKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSPanel {
    // Stop macOS from pushing the window below the menu bar
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: OverlayWindow!
    var scene: SnowScene!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem!
    var amountItems: [NSMenuItem] = []
    var loginItem: NSMenuItem!
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else { return }
        // A non-activating panel can take a click (to grab a snowball) without stealing focus from your apps
        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // clicks pass straight through
        window.level = .floating                  // above normal windows, below the Dock and menu bar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlaySKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        scene = SnowScene(size: screen.frame.size)
        scene.scaleMode = .resizeFill
        view.presentScene(scene)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        LoginItem.enableOnFirstRun()
        setupMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Stop rendering while the display sleeps or the screen is locked; otherwise SpriteKit
        // logs "no drawables available" because nothing is being shown.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(self, selector: #selector(suspendRendering), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didWakeNotification] {
            ws.addObserver(self, selector: #selector(resumeRendering), name: name, object: nil)
        }
        // Unlocking the screen after opening the lid is another chance to start again
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(resumeRendering),
                                                            name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    /// Paused from the menu. Kept separately because pausing the SKView also pauses the scene:
    /// reading scene.isPaused after a sleep can't tell a menu pause from a sleep pause.
    var userPaused = false

    @objc func suspendRendering() {
        (window.contentView as? SKView)?.isPaused = true
    }

    @objc func resumeRendering() {
        // Stay paused if the user paused snow from the menu
        guard !userPaused else { return }
        (window.contentView as? SKView)?.isPaused = false
        scene.isPaused = false
        scene.lastT = 0          // don't count the time asleep as one long frame
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❄︎"
        let menu = NSMenu()

        pauseItem = NSMenuItem(title: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let amount = NSMenuItem(title: "Snow Amount", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, n) in [("Light", 120), ("Medium", 260), ("Heavy", 500)] {
            let it = NSMenuItem(title: title, action: #selector(setAmount(_:)), keyEquivalent: "")
            it.target = self
            it.tag = n
            it.state = (n == Cfg.targetFlakes) ? .on : .off
            sub.addItem(it)
            amountItems.append(it)
        }
        amount.submenu = sub
        menu.addItem(amount)

        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "c")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "u")
        update.target = self
        menu.addItem(update)
        let version = NSMenuItem(title: "Version \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.delegate = self

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func togglePause() {
        userPaused.toggle()
        if userPaused {
            scene.isPaused = true
            window.orderOut(nil)
            pauseItem.title = "Resume Snow"
        } else {
            window.orderFrontRegardless()
            resumeRendering()
            pauseItem.title = "Pause Snow"
        }
    }

    @objc func setAmount(_ sender: NSMenuItem) {
        Cfg.targetFlakes = sender.tag
        for it in amountItems { it.state = (it === sender) ? .on : .off }
    }

    @objc func clearSnow() { scene.clearAll() }

    @objc func toggleLaunchAtLogin() {
        if let err = LoginItem.setEnabled(!LoginItem.isEnabled) {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = err
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc func checkForUpdates() { updater.checkForUpdates() }

    @objc func screensChanged() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
    }
}

extension AppDelegate {
    /// Refresh the checkmark each time the menu opens; the user can also change it in System Settings
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = LoginItem.isEnabled ? .on : .off
    }
}
