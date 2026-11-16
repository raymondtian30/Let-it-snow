// Tests for the updater and the snowball physics. Run: zsh test.sh

import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// Version comparison
check(Updater.isNewer("0.2.0", than: "0.1.0"), "0.2.0 > 0.1.0")
check(Updater.isNewer("0.10.0", than: "0.9.1"), "0.10.0 > 0.9.1 (numeric, not text)")
check(Updater.isNewer("1.0", than: "0.9.9"), "1.0 > 0.9.9")
check(!Updater.isNewer("0.2.0", than: "0.2.0"), "same version is not newer")
check(!Updater.isNewer("0.2", than: "0.2.0"), "0.2 == 0.2.0")
check(!Updater.isNewer("0.1.9", than: "0.2.0"), "older is not newer")

// Release JSON
let json = """
{"tag_name":"v0.3.1","html_url":"https://github.com/o/r/releases/tag/v0.3.1",
 "assets":[{"browser_download_url":"https://x/notes.txt"},{"browser_download_url":"https://x/LetItSnow-0.3.1.zip"}]}
"""
let r = Updater.parseRelease(Data(json.utf8))
check(r?.version == "0.3.1", "strips v from tag")
check(r?.zip?.absoluteString == "https://x/LetItSnow-0.3.1.zip", "picks the .zip asset")
check(r?.page.absoluteString == "https://github.com/o/r/releases/tag/v0.3.1", "reads release page")
check(Updater.parseRelease(Data(#"{"tag_name":"1.0","html_url":"https://x","assets":[]}"#.utf8))?.zip == nil, "no zip asset is fine")
check(Updater.parseRelease(Data(#"{"message":"Not Found"}"#.utf8)) == nil, "404 body gives nil")

// Unzipping a release: needs the app zip path as the first argument
if CommandLine.arguments.count > 1 {
    let zip = URL(fileURLWithPath: CommandLine.arguments[1])
    do {
        let app = try Updater.unpack(zip: zip)
        check(app.lastPathComponent == "Let It Snow.app", "unpack finds the app")
    } catch {
        check(false, "unpack: \(error.localizedDescription)")
    }
    // Swapping an installed (older) copy for the downloaded one
    do {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let installed = folder.appendingPathComponent("Let It Snow.app")
        try fm.copyItem(at: try Updater.unpack(zip: zip), to: installed)
        let plist = installed.appendingPathComponent("Contents/Info.plist")
        let old = NSMutableDictionary(contentsOf: plist)!
        old["CFBundleShortVersionString"] = "0.0.1"
        old.write(to: plist, atomically: true)
        try Updater.replace(installed, with: try Updater.unpack(zip: zip))
        let after = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
        check(after != nil && after != "0.0.1", "replace installs the new version (now \(after ?? "nil"))")
        let leftovers = try fm.contentsOfDirectory(atPath: folder.path)
        check(leftovers == ["Let It Snow.app"], "replace leaves no staging copy (\(leftovers))")
        let v = Process()
        v.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        v.arguments = ["--verify", "--deep", "--strict", installed.path]
        try v.run(); v.waitUntilExit()
        check(v.terminationStatus == 0, "replaced app keeps a valid signature")
    } catch {
        check(false, "replace: \(error.localizedDescription)")
    }

    // A zip without the app must be rejected
    let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try? "x".write(to: bad.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
    let badZip = bad.appendingPathExtension("zip")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", bad.path, badZip.path]
    try? p.run(); p.waitUntilExit()
    check((try? Updater.unpack(zip: badZip)) == nil, "unpack rejects a zip without the app")
}

MainActor.assumeIsolated { runPhysicsTests() }

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
