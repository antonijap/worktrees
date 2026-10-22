import Foundation

/// Asks GitHub, through gh like every other GitHub request, whether a newer release is out.
/// Once a day at most, only while gh is signed in, and only when Settings allows it.
enum UpdateCheck {
    static let repo = "antonijap/worktrees"
    static let lastCheckKey = "lastUpdateCheck"
    static let interval: TimeInterval = 24 * 60 * 60

    struct Release: Equatable, Sendable {
        let version: String
        let url: URL
    }

    /// This build's version; nil for a bare executable, which has no Info.plist to say.
    static var current: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// The latest published release (drafts and pre-releases never count). nil when gh can't say.
    static func latest() async -> Release? {
        let result = await Shell.run("gh", ["api", "repos/\(repo)/releases/latest", "--jq", "[.tag_name, .html_url] | @tsv"])
        let fields = result.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
        guard result.ok, fields.count == 2, let url = URL(string: fields[1]),
              url.scheme == "https", url.host()?.lowercased() == "github.com"
        else { return nil }
        let version = fields[0].hasPrefix("v") ? String(fields[0].dropFirst()) : fields[0]
        guard !numbers(version).isEmpty else { return nil }
        return Release(version: version, url: url)
    }

    private static let savedVersionKey = "latestReleaseVersion"
    private static let savedURLKey = "latestReleaseURL"

    static func save(_ release: Release, in defaults: UserDefaults) {
        defaults.set(release.version, forKey: savedVersionKey)
        defaults.set(release.url.absoluteString, forKey: savedURLKey)
    }

    /// The release last seen, if it is still newer than this build (an upgrade clears it).
    static func saved(in defaults: UserDefaults, newerThan current: String) -> Release? {
        guard let version = defaults.string(forKey: savedVersionKey),
              let raw = defaults.string(forKey: savedURLKey), let url = URL(string: raw),
              url.scheme == "https", url.host()?.lowercased() == "github.com",
              isNewer(version, than: current) else { return nil }
        return Release(version: version, url: url)
    }

    /// 1.10.0 is newer than 1.9.2; 1.0 and 1.0.0 are the same.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }
}
