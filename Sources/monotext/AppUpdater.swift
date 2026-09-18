import AppKit

enum AppUpdater {
    private static let appName = "MonoText"
    private static let latestAPI =
        URL(string: "https://api.github.com/repos/gustaferiksson/monotext/releases/latest")!
    /// Never relax this — an unsigned, wrong-team or wrong-app download must never reach the bundle.
    private static let requirement = "=anchor apple generic"
        + " and certificate leaf[subject.OU] = \"82K3YC8HVF\""
        + " and identifier \"dev.gustaf.monotext\""

    private static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The swap renames the bundle, so the parent directory is what has to be writable.
    private static var installDir: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

    /// Must stay false for a bare `swift build` binary, or the swap would rename the build directory.
    private static var isSelfUpdatable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func check(manual: Bool) {
        guard let current = currentVersion else { return }
        clearStaging()
        Task { @MainActor in
            guard let latest = await fetchLatest() else {
                if manual { alert("Update check failed", "Could not reach github.com.") }
                return
            }
            guard isNewer(latest.version, than: current) else {
                if manual { alert("You’re up to date", "\(appName) \(current) is the latest version.") }
                return
            }
            offer(version: latest.version, asset: latest.asset, page: latest.page)
        }
    }

    @MainActor
    private static func offer(version: String, asset: URL?, page: URL) {
        let installable = asset != nil && isSelfUpdatable
            && FileManager.default.isWritableFile(atPath: installDir.path)
        let panel = NSAlert()
        panel.messageText = "\(appName) \(version) is available"
        panel.informativeText = installable
            ? "\(appName) will download it, replace itself and relaunch."
            : "\(appName) can’t update itself where it is installed — download it from GitHub."
        panel.addButton(withTitle: installable ? "Install" : "Download")
        panel.addButton(withTitle: "Later")
        guard panel.runModal() == .alertFirstButtonReturn else { return }
        guard installable, let asset else {
            NSWorkspace.shared.open(page)
            return
        }
        install(version: version, asset: asset, page: page)
    }

    @MainActor
    private static func install(version: String, asset: URL, page: URL) {
        Task { @MainActor in
            do {
                let staged = try await downloadVerified(version: version, asset: asset)
                try spawnSwap(staged: staged)
                NSApp.terminate(nil)
            } catch {
                clearStaging()
                failed(error.localizedDescription, page: page)
            }
        }
    }

    @MainActor
    private static func failed(_ reason: String, page: URL) {
        let panel = NSAlert()
        panel.messageText = "\(appName) could not install the update"
        panel.informativeText = "\(reason)\n\nYou can download it from GitHub instead."
        panel.addButton(withTitle: "Download")
        panel.addButton(withTitle: "Later")
        guard panel.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(page)
    }

    @MainActor
    private static func alert(_ title: String, _ body: String) {
        let panel = NSAlert()
        panel.messageText = title
        panel.informativeText = body
        panel.runModal()
    }

    private static func fetchLatest() async -> (version: String, asset: URL?, page: URL)? {
        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = version(fromTag: tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return (version, assetURL(in: json, version: version), page)
    }

    private static func assetURL(in json: [String: Any], version: String) -> URL? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        return assets
            .first { $0["name"] as? String == "\(appName)-\(version).zip" }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
    }

    /// `keep` must only flip true once the signature check has passed — the defer deletes anything else.
    private static func downloadVerified(version: String, asset: URL) async throws -> URL {
        let fm = FileManager.default
        let root = installDir.appendingPathComponent(".\(appName)-update-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: root) } }

        let (tmp, response) = try await URLSession.shared.download(from: asset)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw fail("the download failed (HTTP error)")
        }
        let zip = root.appendingPathComponent("\(appName).zip")
        try fm.moveItem(at: tmp, to: zip)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, root.path]) else {
            throw fail("the download could not be unpacked")
        }
        try fm.removeItem(at: zip)

        let app = root.appendingPathComponent("\(appName).app")
        guard bundleVersion(of: app) == version else {
            throw fail("the downloaded app is not version \(version)")
        }
        guard run("/usr/bin/codesign", ["--verify", "--strict", "-R", requirement, app.path]) else {
            throw fail("the downloaded app failed signature checks")
        }
        keep = true
        return app
    }

    /// The helper waits for this process to exit, so it must be spawned before the app terminates.
    private static func spawnSwap(staged: URL) throws {
        let target = Bundle.main.bundleURL
        guard let installed = bundleVersion(of: target) else {
            throw fail("could not read the installed version")
        }
        guard FileManager.default.isWritableFile(atPath: installDir.path) else {
            throw fail("\(installDir.path) is not writable")
        }
        let script = NSTemporaryDirectory() + "\(appName)-update-\(UUID().uuidString).sh"
        try swapScript.write(toFile: script, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script, "\(getpid())", staged.path, target.path, installed]
        try helper.run()
    }

    private static func clearStaging() {
        let fm = FileManager.default
        let leftovers = (try? fm.contentsOfDirectory(atPath: installDir.path)) ?? []
        for entry in leftovers where entry.hasPrefix(".\(appName)-update-") {
            try? fm.removeItem(at: installDir.appendingPathComponent(entry))
        }
    }

    private static func bundleVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Never interpolate a path into this script — pass it as an argument, or it is shell-injectable.
    private static let swapScript = """
    #!/bin/sh
    set -u
    [ "$(id -u)" = "0" ] && exit 1
    pid=$1; staged=$2; target=$3; expected=$4
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i+1)); done
    kill -0 "$pid" 2>/dev/null && exit 1
    [ -d "$staged" ] && [ -d "$target" ] || exit 1
    # Another installer may have replaced the app while we waited, and that install wins.
    now=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
      "$target/Contents/Info.plist" 2>/dev/null)
    [ "$now" = "$expected" ] || exit 1
    backup="$target.old-update"
    rm -rf "$backup"
    mv "$target" "$backup" || exit 1
    if ! mv "$staged" "$target"; then
      mv "$backup" "$target"
      exit 1
    fi
    rm -rf "$backup"
    rm -rf "$(dirname "$staged")"
    open "$target"
    rm -f "$0"
    exit 0
    """

    static func version(fromTag tag: String) -> String? {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty,
              version.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." })
        else { return nil }
        return version
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote), l = components(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
