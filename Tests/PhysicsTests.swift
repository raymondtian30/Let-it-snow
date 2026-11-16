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
}
