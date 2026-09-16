import AppKit

enum AppUpdater {
    private static let latestAPI =
        URL(string: "https://api.github.com/repos/gustaferiksson/monotext/releases/latest")!

    private static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func check(manual: Bool) {
        guard let current = currentVersion else { return }
        Task { @MainActor in
            guard let latest = await fetchLatest() else {
                if manual { alert("Update check failed", "Could not reach github.com.") }
                return
            }
            guard isNewer(latest.version, than: current) else {
                if manual { alert("You’re up to date", "MonoText \(current) is the latest version.") }
                return
            }
            offer(version: latest.version, page: latest.page)
        }
    }

    @MainActor
    private static func offer(version: String, page: URL) {
        let panel = NSAlert()
        panel.messageText = "MonoText \(version) is available"
        panel.informativeText = "Update with `brew upgrade --cask monotext`, or download it from GitHub."
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

    private static func fetchLatest() async -> (version: String, page: URL)? {
        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = version(fromTag: tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return (version, page)
    }

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
