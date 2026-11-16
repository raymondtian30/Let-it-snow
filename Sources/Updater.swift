// Check for updates against GitHub Releases, and start the app at login.

import Cocoa
import ServiceManagement

// MARK: - Launch at login

enum LoginItem {
    private static let setupKey = "didSetUpLoginItem"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turn launch-at-login on the first time the app runs from an Applications folder.
    /// Builds run from elsewhere (like ./build) are left alone.
    static func enableOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: setupKey), isInApplicationsFolder else { return }
        defaults.set(true, forKey: setupKey)
        try? SMAppService.mainApp.register()
    }

    /// Returns an error message, or nil on success.
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(true, forKey: setupKey)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }
}

// MARK: - Updates

final class Updater {
    static let repo = "raymondtian30/Let-it-snow"
    static let bundleID = "local.letitsnow"     // must match CFBundleIdentifier in Info.plist
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    struct Release {
        let version: String
        let page: URL
        let zip: URL?
    }

    private var busy = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "0.10.0" > "0.9.1": compare numerically, part by part
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads the GitHub "latest release" JSON: tag (v1.2.3 or 1.2.3), release page and the first .zip asset
    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.lazy
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".zip") }
            .flatMap(URL.init(string:))
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, page: page, zip: zip)
    }

    func checkForUpdates() {
        guard !busy else { return }
        busy = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let release = status == 200 ? data.flatMap(Updater.parseRelease) : nil
            DispatchQueue.main.async {
                self.busy = false
                if let r = release {
                    self.handle(r)
                } else {
                    let why = err?.localizedDescription ?? (status == 404
                        ? "No public release was found. Update checks only work when the GitHub repository is public."
                        : "GitHub answered with status \(status).")
                    self.showError("Couldn't check for updates", why)
                }
            }
        }.resume()
    }

    private func handle(_ r: Release) {
        let current = Updater.currentVersion
        guard Updater.isNewer(r.version, than: current) else {
            alert("You're up to date", "Let It Snow \(current) is the latest version.", buttons: ["OK"])
            return
        }
        let canInstall = r.zip != nil && FileManager.default.isWritableFile(
            atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
        let buttons = canInstall ? ["Install and Relaunch", "View Release", "Later"] : ["Download", "Later"]
        let choice = alert("Let It Snow \(r.version) is available",
                           "You have version \(current).", buttons: buttons)
        switch (canInstall, choice) {
        case (true, .alertFirstButtonReturn): install(r)
        case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn): NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    /// Download the zip, unpack it next to the running app, swap the bundles and relaunch.
    private func install(_ r: Release) {
        guard let zipURL = r.zip else { return }
        busy = true
        URLSession.shared.downloadTask(with: zipURL) { tmp, resp, err in
            var failure: String?
            var newApp: URL?
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let tmp = tmp, status == 200 {
                do { newApp = try Updater.unpack(zip: tmp) } catch { failure = error.localizedDescription }
            } else {
                failure = err?.localizedDescription ?? "Download failed (status \(status))."
            }
            DispatchQueue.main.async {
                self.busy = false
                if let newApp = newApp {
                    do { try Updater.replaceAndRelaunch(with: newApp) } catch {
                        self.showError("Couldn't install the update", error.localizedDescription, page: r.page)
                    }
                } else {
                    self.showError("Couldn't download the update", failure ?? "Unknown error.", page: r.page)
                }
            }
        }.resume()
    }

    static func unpack(zip: URL) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("LetItSnowUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("The download could not be unzipped.") }
        guard let app = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              Bundle(url: app)?.bundleIdentifier == Updater.bundleID else {
            throw UpdateError("The download does not contain Let It Snow.")
        }
        return app
    }

    /// Swap the app at `current` for `newApp`. Copies into the same folder first so the swap is a same-volume replace.
    static func replace(_ current: URL, with newApp: URL) throws {
        let fm = FileManager.default
        let staged = current.deletingLastPathComponent().appendingPathComponent(".LetItSnow-update.app")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: newApp, to: staged)
        _ = try fm.replaceItemAt(current, withItemAt: staged)
    }

    private static func replaceAndRelaunch(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        try replace(current, with: newApp)
        // Start the new copy once this one has quit
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private func showError(_ title: String, _ detail: String, page: URL = Updater.releasesPage) {
        if alert(title, detail, buttons: ["Open Releases Page", "OK"]) == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        NSApp.activate(ignoringOtherApps: true)   // menu bar apps are never frontmost, so bring the alert forward
        return a.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
