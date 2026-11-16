# ❄︎ Let It Snow

Snow on your Mac desktop, as a menu bar app. Flakes fall in front of your windows and pile up at the bottom of the screen and on the Dock. (Set `pileOnWindows = true` in `Cfg` to also pile snow on window tops, which flies off when you drag the window.) Move the mouse sideways over the snow to roll snowballs, hold one with the left mouse button to carry it, and stack three to build a snowman.

Based on [WinterIsComing](https://github.com/yike-shi/WINTER_IS_COMING) by Shi Yike (MIT).

## Download

Get `LetItSnow-<version>.zip` from the [Releases](../../releases) page, unzip it and move **Let It Snow.app** to Applications.

The app is not notarized by Apple, so the first launch is blocked. Open it once, then go to System Settings → Privacy & Security and click **Open Anyway**. Or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Let It Snow.app"
```

The first time it runs from Applications, Let It Snow turns on **Launch at Login**, so it starts with your Mac. Toggle it in the ❄︎ menu.

**Updates:** ❄︎ menu → **Check for Updates…** looks at the latest GitHub release. If there's a newer version it can download it, replace the app and relaunch. This only works while the GitHub repository is public.

## Build

Requires macOS 13+ and the Swift compiler (`xcode-select --install`).

```sh
zsh build.sh            # builds build/Let It Snow.app (universal: Apple silicon + Intel)
zsh build.sh --run      # builds and launches it
zsh build.sh --install  # builds, copies to ~/Applications and launches it
zsh build.sh --zip      # builds and zips the app for a release (build/LetItSnow-<version>.zip)
zsh test.sh             # builds, then runs the updater tests
```

Use the ❄︎ in the menu bar to pause, choose light, medium or heavy snow, clear the snow, turn Launch at Login on or off, check for updates, or quit.

## Snow on the Dock

Piling snow on the Dock needs Accessibility access: System Settings → Privacy & Security → Accessibility → enable **Let It Snow**. The app is ad-hoc signed, so after a rebuild macOS may treat it as a new app. If Dock snow stops working, remove the old entry and add it again.

## Tweaking

All settings are at the top of [Sources/LetItSnow.swift](Sources/LetItSnow.swift) in `enum Cfg`.

## Layout

```
Sources/main.swift        entry point
Sources/LetItSnow.swift   the snow (SpriteKit scene, overlay window, menu bar item)
Sources/Updater.swift     Check for Updates (GitHub Releases) and Launch at Login
Tests/main.swift          updater tests, run with test.sh
Resources/Info.plist      bundle metadata (menu bar only, no Dock icon)
build.sh                  compiles, assembles and ad-hoc signs the .app
```

## Releasing a new version

1. Raise `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. `zsh test.sh` (this also builds `build/LetItSnow-<version>.zip`).
3. Commit, then `git tag v<version> && git push origin main v<version>`.
4. `gh release create v<version> build/LetItSnow-<version>.zip --title "Let It Snow <version>"`

The tag must be the version with a `v` in front, and the release needs the `.zip` attached, so the updater can find it.

## License

[MIT](LICENSE)
