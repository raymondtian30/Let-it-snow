// Snowball physics tests: a real SnowScene with no window, driven by a simulated mouse.

import Cocoa
import SpriteKit

@MainActor func runPhysicsTests() {
    let dt: CGFloat = 1.0 / 60.0

    func makeScene(depth: CGFloat) -> (SnowScene, Pile) {
        let sc = SnowScene(size: CGSize(width: 1200, height: 700))
        sc.didMove(to: SKView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700)))
        let g = sc.ground!
        for c in 0..<g.count { g.h[c] = min(g.caps[c], depth) }
        return (sc, g)
    }

    /// Move the mouse along the snow from x0 to x1 over n frames, then hold it still for `rest` frames
    func drive(_ sc: SnowScene, _ g: Pile, from x0: CGFloat, to x1: CGFloat, frames n: Int, rest: Int = 0,
               each: (() -> Void)? = nil) {
        let y = g.topY + 8
        sc.lastMouse = CGPoint(x: x0, y: y)
        for k in 0...(n + rest) {
            let x = x0 + (x1 - x0) * CGFloat(min(k, n)) / CGFloat(n)
            sc.updateRolling(dt, mouse: CGPoint(x: x, y: y))
            sc.stepBalls(dt)
            if g.dirty { g.redraw() }
            each?()
        }
    }

    func newBall(_ sc: SnowScene, _ g: Pile, x: CGFloat, r: CGFloat) -> Snowball {
        let b = Snowball(body: sc.ballTex!, specks: sc.speckTex!)
        b.x = x
        b.r = r
        b.pile = g
        b.y = sc.restY(b, on: g)
        sc.world.addChild(b.node)
        sc.balls.append(b)
        return b
    }

    // 1. Rolling through snow: the ball grows, rides on the snow and leaves a packed track
    do {
        let (sc, g) = makeScene(depth: 14)
        drive(sc, g, from: 200, to: 500, frames: 60)
        check(sc.balls.count == 1, "rolling makes one snowball (\(sc.balls.count))")
        if let b = sc.balls.first {
            check(b.r > Cfg.ballStartRadius + 3, "ball grows while rolling (r = \(Int(b.r)))")
            check(b.y - b.r > g.topY + 2, "ball rides on the snow, not inside it (bottom \(Int(b.y - b.r - g.topY)) px above ground)")
            let track = g.surfaceAt(320) - g.topY, fresh = g.surfaceAt(900) - g.topY
            check(track < fresh - 2, "rolled path is lower than fresh snow (\(Int(track)) vs \(Int(fresh)) px)")
        }
    }

    // 2. The ball follows the cursor: it stops when the mouse stops
    do {
        let (sc, g) = makeScene(depth: 6)
        drive(sc, g, from: 200, to: 500, frames: 50)   // 360 px/s
        let b = sc.balls.first!
        let stopX = b.x
        drive(sc, g, from: 500, to: 500, frames: 1, rest: 120)
        check(abs(b.x - stopX) < 1, "ball stops when the mouse stops (drifted \(String(format: "%.1f", b.x - stopX)) px)")
        check(b.vx == 0 && !b.falling, "ball rests on the snow")
    }

    // 3. Collisions: a rolling ball knocks a resting one ahead and they never overlap
    do {
        let (sc, g) = makeScene(depth: 4)
        let target = newBall(sc, g, x: 600, r: 10)
        var minGap = CGFloat.greatestFiniteMagnitude
        drive(sc, g, from: 300, to: 640, frames: 34, rest: 240) {   // 600 px/s, into and through the resting ball
            guard let a = sc.balls.first(where: { $0 !== target }) else { return }
            minGap = min(minGap, (target.x - a.x) - sc.touchDist(a, target))
        }
        check(target.x > 650, "hit ball is knocked along (moved \(Int(target.x - 600)) px)")
        check(target.x < 820, "hit ball doesn't roll far after the shove (stopped at \(Int(target.x)), mouse stopped at 640)")
        check(minGap > -1, "balls never overlap (closest gap \(String(format: "%.1f", minGap)) px)")
        check(target.vx == 0 && !target.falling, "knocked ball comes to rest on the snow")
    }

    // 4. Slopes: a ball on a steep bank rolls down it
    do {
        let (sc, g) = makeScene(depth: 0)
        for c in 0..<g.count {
            let x = g.colX(c)
            g.h[c] = x < 100 ? 34 : max(0, 34 - (x - 100))   // 45° bank, sloping down to the right
        }
        let b = newBall(sc, g, x: 112, r: 8)
        for _ in 0..<120 { sc.stepBalls(dt) }
        check(b.x > 127, "ball rolls down the bank toward its foot at x=134 (moved \(Int(b.x - 112)) px)")
    }

    // 5. Flat snow: a resting ball stays put
    do {
        let (sc, g) = makeScene(depth: 10)
        let b = newBall(sc, g, x: 600, r: 12)
        for _ in 0..<120 { sc.stepBalls(dt) }
        check(abs(b.x - 600) < 0.01 && b.vx == 0, "resting ball on flat snow stays put")
    }

    // 6. Screen edge: a fast ball bounces off it and stays on screen
    do {
        let (sc, g) = makeScene(depth: 4)
        let b = newBall(sc, g, x: 1100, r: 10)
        b.vx = 800
        for _ in 0..<120 { sc.stepBalls(dt) }
        check(!b.falling && b.x <= 1200 - b.r + 0.01, "ball stops at the screen edge (x = \(Int(b.x)))")
    }

    // 7. A snowman base can't be shoved
    do {
        let (sc, g) = makeScene(depth: 4)
        let base = newBall(sc, g, x: 600, r: 14)
        let top = newBall(sc, g, x: 600, r: 10)
        top.pile = nil
        top.below = base
        drive(sc, g, from: 400, to: 590, frames: 20, rest: 60)
        check(abs(base.x - 600) < 0.01, "snowman base doesn't move when hit")
    }

    /// Drop a ball of radius r so its bottom starts `height` px above the snow; run until it lands
    func dropTest(height: CGFloat, r: CGFloat, depth: CGFloat = 6, vx: CGFloat = 0) -> (SnowScene, Pile, Snowball, CGFloat) {
        let (sc, g) = makeScene(depth: depth)
        let b = newBall(sc, g, x: 600, r: r)
        let snowBefore = g.h.reduce(0, +)
        b.y = g.surface(g.col(at: 600)!) + height + r
        b.drop(vel: CGVector(dx: vx, dy: 0))
        for _ in 0..<240 { sc.stepBalls(dt) }
        return (sc, g, b, g.h.reduce(0, +) - snowBefore)
    }

    // 8. A short drop: the ball lands whole and rests on the snow
    do {
        let (sc, _, b, added) = dropTest(height: 25, r: 12)
        check(sc.balls.contains { $0 === b }, "ball dropped from 25 px survives")
        check(!b.falling && b.pile != nil, "it rests on the snow")
        check(abs(b.r - 12) < 0.01 && added < 1, "and stays whole (r = \(String(format: "%.1f", b.r)))")
    }

    // 9. A medium drop: part of the ball breaks off into the snow, the rest lands
    do {
        let (sc, _, b, added) = dropTest(height: 140, r: 12)
        check(sc.balls.contains { $0 === b } && !b.falling, "ball dropped from 140 px survives")
        check(b.r < 11.5 && b.r > Cfg.ballStartRadius, "but loses part of its snow (r = \(String(format: "%.1f", b.r)))")
        check(added > 1, "the broken part piles up on the snow (+\(Int(added)))")
    }

    // 10. A high drop: the ball bursts completely
    do {
        let (sc, _, b, added) = dropTest(height: 450, r: 12)
        check(!sc.balls.contains { $0 === b }, "ball dropped from 450 px bursts")
        check(added > 5, "into a heap of snow (+\(Int(added)))")
    }

    // 11. Letting go of a ball that bursts right under the cursor doesn't start a new ball there,
    // until the cursor moves away
    do {
        let (sc, g) = makeScene(depth: 4)
        let b = newBall(sc, g, x: 600, r: 12)
        let m = CGPoint(x: 600, y: g.topY + 8)
        sc.grab(b, at: m)
        b.y = g.topY + 500                   // as if the drop was a hard one
        sc.letGo(at: m)
        for _ in 0..<240 { sc.stepBalls(dt) }
        check(sc.balls.isEmpty, "ball burst into a heap under the cursor")
        drive(sc, g, from: 600, to: 630, frames: 15)
        check(sc.balls.isEmpty, "moving the mouse over the heap doesn't start a new ball (\(sc.balls.count))")
        drive(sc, g, from: 630, to: 900, frames: 30)
        check(sc.balls.count == 1, "moving away re-enables rolling new balls (\(sc.balls.count))")
    }

    // 12. Big balls are heavy for their strength: the same drop breaks a big ball but not a small one
    do {
        let (_, _, small, _) = dropTest(height: 70, r: 6)
        let (_, _, big, _) = dropTest(height: 70, r: 26)
        check(abs(small.r - 6) < 0.01, "small ball survives a 70 px drop whole (r = \(String(format: "%.1f", small.r)))")
        check(big.r < 25.5, "big ball loses snow from the same drop (r = \(String(format: "%.1f", big.r)) of 26)")
    }

    // 13. Deep powder cushions a fall; bare ground doesn't
    do {
        let (_, _, bare, _) = dropTest(height: 120, r: 12, depth: 0)
        let (_, _, soft, _) = dropTest(height: 120, r: 12, depth: 30)
        check(bare.r < 11.5, "ball dropped on bare ground breaks (r = \(String(format: "%.1f", bare.r)))")
        check(abs(soft.r - 12) < 0.01, "the same drop into deep snow keeps it whole (r = \(String(format: "%.1f", soft.r)))")
    }

    // 14. A landing digs a dent and pushes snow up into a rim around it
    do {
        let (_, g, b, _) = dropTest(height: 100, r: 12, depth: 20)
        let mid = g.surfaceAt(600) - g.topY
        let rim = max(g.surfaceAt(600 - 16), g.surfaceAt(600 + 16)) - g.topY
        check(!b.falling && abs(b.r - 12) < 0.01, "ball lands whole in deep snow")
        check(mid < 17, "landing digs a dent (\(String(format: "%.1f", mid)) px, was 20)")
        check(rim > 20.5, "and piles a rim beside it (\(String(format: "%.1f", rim)) px, was 20)")
    }

    // 15. Only the downward speed breaks a ball: a low, fast sideways throw lands whole and rolls on
    do {
        let (sc, _, b, _) = dropTest(height: 40, r: 12, vx: 700)
        check(sc.balls.contains { $0 === b } && b.r > 11.5, "sideways throw doesn't break the ball (r = \(String(format: "%.1f", b.r)))")
        check(b.x > 700, "it keeps rolling after landing (x = \(Int(b.x)))")
    }

    /// Drop ball a (radius ra) from `height` above resting ball b (radius rb), offset sideways by dx
    func ballOnBall(ra: CGFloat, rb: CGFloat, dx: CGFloat, height: CGFloat)
        -> (SnowScene, Snowball, Snowball, CGFloat) {
        let (sc, g) = makeScene(depth: 4)
        let b = newBall(sc, g, x: 600, r: rb)
        let a = newBall(sc, g, x: 600 + dx, r: ra)
        a.y = b.y + rb + ra + height
        a.drop(vel: .zero)
        var minGap = CGFloat.greatestFiniteMagnitude
        for _ in 0..<240 {
            sc.stepBalls(dt)
            if sc.balls.contains(where: { $0 === a }) && sc.balls.contains(where: { $0 === b }) {
                minGap = min(minGap, hypot(a.x - b.x, a.y - b.y) - (a.r + b.r))
            }
        }
        return (sc, a, b, minGap)
    }

    // 16. A ball falling onto another one doesn't pass through it
    do {
        let (sc, a, b, gap) = ballOnBall(ra: 8, rb: 12, dx: 11, height: 150)
        check(gap > -3, "falling ball doesn't pass through a resting one (closest \(String(format: "%.1f", gap)) px)")
        check(sc.balls.contains { $0 === a } && sc.balls.contains { $0 === b }, "a glancing hit breaks neither")
        check(abs(a.x - b.x) >= sc.touchDist(a, b) - 1, "the falling ball ends up beside it, not inside it")
    }

    // 17. Dropped gently and centered, it lands on top and stacks
    do {
        let (_, a, b, _) = ballOnBall(ra: 8, rb: 12, dx: 1, height: 15)
        check(a.below === b && !a.falling, "a gentle centered drop stacks on the ball below")
    }

    // 18. A heavy ball falling hard onto a small one crushes the small one
    do {
        let (sc, a, b, _) = ballOnBall(ra: 22, rb: 6, dx: 2, height: 400)
        check(!sc.balls.contains { $0 === b }, "small ball is crushed by a heavy one falling on it")
        check(sc.balls.contains { $0 === a } || a.falling == false, "the heavy ball carries on")
    }

    // 19. A snowman's head and middle tumbling off when the base is grabbed never get stuck inside each other
    do {
        let (sc, g) = makeScene(depth: 6)
        let base = newBall(sc, g, x: 600, r: 16)
        let mid = newBall(sc, g, x: 600, r: 12); mid.pile = nil; mid.below = base
        let head = newBall(sc, g, x: 600, r: 9); head.pile = nil; head.below = mid
        sc.stepBalls(dt)
        sc.grab(base, at: CGPoint(x: 600, y: base.y))
        for _ in 0..<240 { sc.stepBalls(dt) }
        let rest = sc.balls.filter { $0 !== base && !$0.falling && $0.below == nil }
        var ok = true
        for i in 0..<rest.count { for j in (i + 1)..<rest.count where rest[i].pile === rest[j].pile {
            if abs(rest[i].x - rest[j].x) < sc.touchDist(rest[i], rest[j]) - 1 { ok = false }
        } }
        check(ok, "tumbled snowman parts don't overlap after landing")
        check(sc.balls.allSatisfy { !$0.falling }, "they all come to rest")
    }

    // 20. A partial break: the broken snow lands beside the ball, not under it, and the ball shrinks
    // smoothly instead of popping to its new size
    do {
        let (sc, g) = makeScene(depth: 6)
        let b = newBall(sc, g, x: 600, r: 12)
        b.y = g.surface(g.col(at: 600)!) + 140 + 12
        b.drop(vel: .zero)
        var rs: [CGFloat] = []
        var landedAt = -1
        for f in 0..<240 {
            sc.stepBalls(dt)
            if landedAt < 0 && !b.falling { landedAt = f }
            rs.append(b.r)
        }
        let final = b.r
        check(final < 11.5, "ball loses snow in the partial break (r = \(String(format: "%.1f", final)))")
        check(g.surfaceAt(600) - g.topY <= 6.01, "no mound under the ball (\(String(format: "%.1f", g.surfaceAt(600) - g.topY)) px, was 6)")
        let side = stride(from: 612, through: 626, by: 2).map { max(g.surfaceAt(CGFloat(600 - ($0 - 600))), g.surfaceAt(CGFloat($0))) }.max()! - g.topY
        check(side > 6.5, "broken snow piles up beside the ball (\(String(format: "%.1f", side)) px)")
        var maxStep: CGFloat = 0
        for i in 1..<rs.count { maxStep = max(maxStep, rs[i - 1] - rs[i]) }
        check(maxStep < (12 - final) * 0.5, "ball shrinks over several frames (biggest step \(String(format: "%.2f", maxStep)) of \(String(format: "%.2f", 12 - final)))")
        check(landedAt >= 0 && abs(rs[min(rs.count - 1, landedAt + 18)] - final) < 0.05, "and reaches its new size within 0.3 s")
    }

    // 21. Snow settles: even the heaviest snowfall levels off below the height limit (ground and Dock)
    do {
        let saved = Cfg.targetFlakes
        Cfg.targetFlakes = 500                          // "Heavy"
        let sc = SnowScene(size: CGSize(width: 1470, height: 956))
        sc.didMove(to: SKView(frame: NSRect(x: 0, y: 0, width: 1470, height: 956)))
        let g = sc.ground!
        let dr = CGRect(x: 400, y: 0, width: 670, height: 70)
        sc.dockRect = dr
        let d = Pile(minX: dr.minX, topY: dr.maxY, width: dr.width, maxH: Cfg.dockPileMax, parent: sc.world)
        d.settleScale = Cfg.dockSettleScale
        sc.dockPile = d
        // Each column's average height over the last 5 minutes: the level you see, not single-flake spikes
        var gSum = [CGFloat](repeating: 0, count: g.count), dSum = [CGFloat](repeating: 0, count: d.count)
        for sec in 1...600 {                            // 10 minutes
            for _ in 0..<20 { sc.stepFlakes(1.0 / 20); sc.settle(1.0 / 20) }
            if g.dirty { g.redraw() }
            if d.dirty { d.redraw() }
            if sec > 300 {
                for c in 0..<g.count { gSum[c] += g.h[c] / 300 }
                for c in 0..<d.count { dSum[c] += d.h[c] / 300 }
            }
        }
        // Only full-height columns: the tapered tips at each end are meant to sit at their (small) cap
        let gPeak = (0..<g.count).filter { g.caps[$0] >= g.maxH * 0.999 && !(400...1070).contains(g.colX($0)) }
            .map { gSum[$0] / g.caps[$0] }.max() ?? 0
        let dPeak = (0..<d.count).filter { d.caps[$0] >= d.maxH * 0.999 }.map { dSum[$0] / d.caps[$0] }.max() ?? 0
        Cfg.targetFlakes = saved
        check(gPeak < 0.85, "heavy snow on the ground levels off below the limit (peak \(Int(gPeak * 100))% of max)")
        check(gPeak > 0.4, "but still builds up a real layer (peak \(Int(gPeak * 100))%)")
        check(dPeak < 0.85, "heavy snow on the Dock levels off below the limit (peak \(Int(dPeak * 100))% of max)")
    }

    // 22. A thin layer of snow barely settles
    do {
        let (sc, g) = makeScene(depth: 4)
        for _ in 0..<(60 * 20) { sc.settle(1.0 / 20) }   // one minute
        let left = g.h[g.count / 2]
        check(left > 3.5, "4 px of snow loses less than 0.5 px in a minute (now \(String(format: "%.2f", left)))")
    }

    // 23. Snow piles on a window's top, never shows over its face, levels off below the max, and falls to the
    // ground when the window is moved
    do {
        let saved = Cfg.targetFlakes
        Cfg.targetFlakes = 500
        let sc = SnowScene(size: CGSize(width: 1470, height: 956))
        sc.didMove(to: SKView(frame: NSRect(x: 0, y: 0, width: 1470, height: 956)))
        let g = sc.ground!
        var rect = CGRect(x: 400, y: 300, width: 600, height: 400)
        sc.applyWindows([(id: 7, rect: rect)], dt: 1.0 / 20)
        var overFace = 0
        var wSum: [CGFloat] = []
        for sec in 1...600 {
            for _ in 0..<20 {
                sc.stepFlakes(1.0 / 20)
                sc.settle(1.0 / 20)
                sc.applyWindows([(id: 7, rect: rect)], dt: 1.0 / 20)
                for f in sc.flakes where !f.node.isHidden && rect.insetBy(dx: 2, dy: 2).contains(f.node.position) { overFace += 1 }
            }
            if sec > 300, let w = sc.piles[7] {
                if wSum.isEmpty { wSum = [CGFloat](repeating: 0, count: w.count) }
                for c in 0..<w.count { wSum[c] += w.h[c] / 300 }
            }
        }
        let w = sc.piles[7]!
        check(w.total / CGFloat(w.count) > 2, "snow piles up on top of a window (avg \(String(format: "%.1f", w.total / CGFloat(w.count))) px)")
        check(overFace == 0, "no snow is drawn over a window's face (\(overFace) flake-frames)")
        let wPeak = (0..<w.count).filter { w.caps[$0] >= w.maxH * 0.999 }.map { wSum[$0] / w.caps[$0] }.max() ?? 1
        check(wPeak < 0.85, "heavy snow on a window levels off below the limit (peak \(Int(wPeak * 100))% of max)")

        // Let the sky empty out, then drag the window: its snow falls to the ground instead of vanishing
        Cfg.targetFlakes = 0
        for _ in 0..<(20 * 20) { sc.stepFlakes(1.0 / 20); sc.applyWindows([(id: 7, rect: rect)], dt: 1.0 / 20) }
        let onWindow = w.total
        let groundBefore = g.total
        rect.origin.x += 60
        sc.applyWindows([(id: 7, rect: rect)], dt: 1.0 / 20)
        check(sc.piles[7]!.total < 0.5, "moving the window knocks its snow off")
        for _ in 0..<(20 * 20) { sc.stepFlakes(1.0 / 20); sc.applyWindows([(id: 7, rect: rect)], dt: 1.0 / 20) }
        let gained = g.total - groundBefore
        check(gained > onWindow * 0.5, "the knocked-off snow lands on the ground (+\(Int(gained)) for \(Int(onWindow)) on the window)")
        Cfg.targetFlakes = saved
    }

    /// A scene with one window (id 1) whose top is covered in `depth` px of snow
    func windowScene(_ rect: CGRect, depth: CGFloat) -> (SnowScene, Pile) {
        let (sc, _) = makeScene(depth: 0)
        sc.applyWindows([(id: 1, rect: rect)], dt: 1.0 / 30)
        let w = sc.piles[1]!
        for c in 0..<w.count { w.h[c] = min(w.caps[c], depth) }
        w.dirty = true
        for _ in 0..<300 { sc.applyWindows([(id: 1, rect: rect)], dt: 1.0 / 30) }   // let the snow slump into shape
        return (sc, w)
    }

    // 24. Snow covered by another window is kept, not deleted, and shows again when the window comes back to front
    do {
        let a = CGRect(x: 200, y: 200, width: 500, height: 300)
        let (sc, w) = windowScene(a, depth: 8)
        let before = w.total
        let b = CGRect(x: 450, y: 100, width: 500, height: 500)   // covers the right half of a's top
        sc.applyWindows([(id: 2, rect: b), (id: 1, rect: a)], dt: 1.0 / 30)
        check(w.occ.contains(true), "the covered part of the snow is hidden")
        check(abs(w.total - before) < before * 0.005, "covering a window's snow doesn't delete it")
        sc.applyWindows([(id: 1, rect: a), (id: 2, rect: b)], dt: 1.0 / 30)
        check(!w.occ.contains(true) && abs(w.total - before) < before * 0.005, "it shows again when the window comes to the front")
    }

    // 25. A minimized / hidden window keeps its snow; only a closed window drops it
    do {
        let a = CGRect(x: 200, y: 200, width: 500, height: 300)
        let (sc, w) = windowScene(a, depth: 8)
        let before = w.total
        sc.windowExists = { _ in true }                 // still exists, just not on screen
        sc.applyWindows([], dt: 1.0 / 30)
        check(sc.piles[1] === w && abs(w.total - before) < before * 0.005, "a hidden window keeps its snow")
        check(!w.occ.contains(false), "and it isn't drawn while the window is hidden")
        sc.applyWindows([(id: 1, rect: a)], dt: 1.0 / 30)
        check(abs(w.total - before) < before * 0.005 && !w.occ.contains(true), "it's back when the window shows again")
        sc.windowExists = { _ in false }                // closed
        sc.applyWindows([], dt: 1.0 / 30)
        check(sc.piles[1] == nil, "a closed window's snow falls off")
    }

    // 26. Resizing drops only the snow that lost its support
    do {
        let a = CGRect(x: 200, y: 200, width: 600, height: 300)
        let (sc, w) = windowScene(a, depth: 8)
        let full = w.total
        let clumpsBefore = sc.flakes.filter { $0.isClump }.count
        sc.applyWindows([(id: 1, rect: CGRect(x: 200, y: 200, width: 400, height: 300))], dt: 1.0 / 30)
        let n = sc.piles[1]!
        check(n.total > full * 0.55 && n.total < full * 0.75, "narrowing a window keeps the snow still on top (\(Int(n.total)) of \(Int(full)))")
        check(sc.flakes.filter { $0.isClump }.count > clumpsBefore, "and the part past the new edge falls")
        for _ in 0..<300 { sc.applyWindows([(id: 1, rect: CGRect(x: 200, y: 200, width: 400, height: 300))], dt: 1.0 / 30) }
        let kept = n.total
        sc.applyWindows([(id: 1, rect: CGRect(x: 200, y: 200, width: 400, height: 380))], dt: 1.0 / 30)
        check(abs(sc.piles[1]!.total - kept) < kept * 0.005, "dragging the top edge up carries the snow along")
        check(abs(sc.piles[1]!.topY - 580) < 0.01, "on the new top edge")
    }

    // 27. With a big window in the way, snow still piles on its top and at the bottom of the screen
    do {
        let saved = Cfg.targetFlakes
        Cfg.targetFlakes = 500
        let sc = SnowScene(size: CGSize(width: 1470, height: 956))
        sc.didMove(to: SKView(frame: NSRect(x: 0, y: 0, width: 1470, height: 956)))
        let r = CGRect(x: 0, y: 0, width: 1470, height: 900)   // nearly full screen
        for _ in 0..<(120 * 20) { sc.stepFlakes(1.0 / 20); sc.applyWindows([(id: 1, rect: r)], dt: 1.0 / 20) }
        Cfg.targetFlakes = saved
        let g = sc.ground!
        check(sc.piles[1]!.total / CGFloat(sc.piles[1]!.count) > 1, "snow piles on top of the window")
        check(g.total / CGFloat(g.count) > 1, "and at the bottom of the screen (avg \(String(format: "%.1f", g.total / CGFloat(g.count))) px)")
        check(!g.occ.contains(true), "the bottom pile is drawn in front of windows")
    }

    // 28. Hovering doesn't make a snowball; press and drag does
    do {
        let (sc, g) = makeScene(depth: 10)
        let y = g.topY + 5
        sc.lastMouse = CGPoint(x: 300, y: y)
        for k in 0...40 { sc.stepMouse(dt, mouse: CGPoint(x: 300 + CGFloat(k) * 5, y: y)); sc.stepBalls(dt) }
        check(sc.balls.isEmpty, "hovering over the snow doesn't make a ball")
        sc.pressDown(at: CGPoint(x: 500, y: y))
        for k in 0...40 { sc.stepMouse(dt, mouse: CGPoint(x: 500 + CGFloat(k) * 5, y: y)); sc.stepBalls(dt) }
        check(sc.balls.count == 1, "pressing and dragging over the snow rolls a ball (\(sc.balls.count))")
        sc.pressUp(at: CGPoint(x: 700, y: y))
        let n = sc.balls.count, x = sc.balls.first?.x ?? 0
        for k in 0...40 { sc.stepMouse(dt, mouse: CGPoint(x: 700 + CGFloat(k) * 5, y: y)); sc.stepBalls(dt) }
        check(sc.balls.count == n && abs((sc.balls.first?.x ?? 0) - x) < 1, "after letting go, hovering doesn't roll it")
        check(sc.wantsMouse(at: CGPoint(x: 900, y: y)), "the snow catches clicks")
        check(!sc.wantsMouse(at: CGPoint(x: 900, y: g.topY + 40)), "the empty air above it doesn't")
        // The bottom snow is in front of windows: it can be rolled even where a window reaches the bottom
        sc.rolling = false
        sc.balls.removeAll()
        sc.applyWindows([(id: 3, rect: CGRect(x: 0, y: 0, width: 1200, height: 600))], dt: dt)
        check(sc.wantsMouse(at: CGPoint(x: 300, y: y)), "bottom snow in front of a window catches clicks")
        sc.pressDown(at: CGPoint(x: 300, y: y))
        for k in 0...40 { sc.stepMouse(dt, mouse: CGPoint(x: 300 + CGFloat(k) * 5, y: y)); sc.stepBalls(dt) }
        check(sc.balls.count == 1, "and rolls a ball there (\(sc.balls.count))")
        sc.pressUp(at: CGPoint(x: 500, y: y))
        check(!sc.wantsMouse(at: CGPoint(x: 600, y: 300)), "a window's face still gets its own clicks")
    }

    // 29. Dragging any ball of a snowman moves the whole snowman, face and all
    do {
        let (sc, g) = makeScene(depth: 4)
        let base = newBall(sc, g, x: 600, r: 16)
        let mid = newBall(sc, g, x: 600, r: 12)
        let head = newBall(sc, g, x: 600, r: 9)
        sc.stack(mid, on: base)
        sc.stack(head, on: mid)
        for _ in 0..<5 { sc.stepBalls(dt) }
        check(head.decor != nil, "three stacked balls make a snowman")
        let start = CGPoint(x: head.x, y: head.y)
        sc.grab(head, at: start)
        check(sc.dragBall === base, "grabbing the head drags the whole snowman")
        for k in 1...20 {
            sc.dragTarget = CGPoint(x: start.x + CGFloat(k) * 5, y: start.y + CGFloat(k))
            sc.stepDrag(sc.dragBall!, dt)
            sc.stepBalls(dt)
        }
        check(abs(base.x - 700) < 1 && abs(mid.x - 700) < 1 && abs(head.x - 700) < 1, "all three balls move together")
        check(head.below === mid && mid.below === base && head.decor != nil, "the snowman stays in one piece")
        sc.letGo(at: sc.dragTarget)
        for _ in 0..<240 { sc.stepBalls(dt) }
        check(!base.falling && base.pile != nil, "let go, it lands")
        check(head.below === mid && mid.below === base && head.decor != nil, "still a snowman after landing")
    }
}
