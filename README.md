# ❄︎ Let It Snow

Snow on your Mac desktop, as a menu bar app. Flakes fall over your screen and pile up on windows, the Dock and the bottom of the screen. Drag a window and the snow flies off. Move the mouse sideways over the snow to roll snowballs, hold one with the left mouse button to carry it, and stack three to build a snowman.

Based on [WinterIsComing](https://github.com/yike-shi/WINTER_IS_COMING) by Shi Yike (MIT).

## Build

Requires macOS 13+ and the Swift compiler (`xcode-select --install`).

```sh
zsh build.sh            # builds build/Let It Snow.app (universal: Apple silicon + Intel)
zsh build.sh --run      # builds and launches it
zsh build.sh --install  # builds, copies to ~/Applications and launches it
```

Use the ❄︎ in the menu bar to pause, choose light, medium or heavy snow, clear the snow, or quit.

## Snow on the Dock

Piling snow on the Dock needs Accessibility access: System Settings → Privacy & Security → Accessibility → enable **Let It Snow**. The app is ad-hoc signed, so after a rebuild macOS may treat it as a new app. If Dock snow stops working, remove the old entry and add it again.

## Tweaking

All settings are at the top of [Sources/LetItSnow.swift](Sources/LetItSnow.swift) in `enum Cfg`.

## Layout

```
Sources/LetItSnow.swift   the whole app (SpriteKit scene, overlay window, menu bar item)
Resources/Info.plist      bundle metadata (menu bar only, no Dock icon)
build.sh                  compiles, assembles and ad-hoc signs the .app
```

## License

[MIT](LICENSE)
