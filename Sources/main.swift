// Entry point for Let It Snow. The app itself lives in LetItSnow.swift; updates and the login item in Updater.swift.

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
