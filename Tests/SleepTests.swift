// Sleep / wake: the snow must start again after the display sleeps (lid closed), unless paused from the menu.

import Cocoa
import SpriteKit

@MainActor func runSleepTests() {
    // An overlay that is never shown, so the scene never runs a frame (no Dock lookup, no Accessibility prompt)
    let d = AppDelegate()
    let view = SKView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    d.scene = SnowScene(size: CGSize(width: 400, height: 300))
    view.presentScene(d.scene)
    d.window = OverlayWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    d.window.contentView = view

    d.suspendRendering()                       // display sleeps
    d.resumeRendering()                        // display wakes
    check(!view.isPaused && !d.scene.isPaused, "snow runs again after sleep and wake")

    d.suspendRendering()
    d.resumeRendering()
    d.resumeRendering()                        // wake + unlock both fire
    check(!view.isPaused && !d.scene.isPaused, "snow runs after several wake notifications")

    d.userPaused = true                        // paused from the menu, then the Mac sleeps and wakes
    d.scene.isPaused = true
    d.suspendRendering()
    d.resumeRendering()
    check(d.scene.isPaused, "menu pause survives sleep and wake")
}
