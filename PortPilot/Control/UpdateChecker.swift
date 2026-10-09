import Foundation

// The update check: one GET to GitHub's "latest release" endpoint. It is PortPilot's only outgoing network
// request and carries no identifiers: an ephemeral session (no cookies, no cache), a fixed User-Agent with the app
// version, nothing else. Nothing is downloaded or installed automatically.

/// Dotted numeric versions ("1.10.0", "v2.0"), compared component by component.
enum AppVersion {
    /// [1, 10, 0] for "1.10.0" or "v1.10.0"; nil for anything else ("", "1.2.0-beta", "latest", "1..2").
    static func components(_ string: String) -> [Int]? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// "1.2.0" for "v1.2.0"; nil when malformed.
    static func normalized(_ string: String) -> String? {
        components(string).map { $0.map(String.init).joined(separator: ".") }
    }

    /// Compares numerically with missing components treated as 0 ("1.2" == "1.2.0"); nil if either is malformed.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = components(lhs), let b = components(rhs) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True only when both versions are well formed and `candidate` is strictly newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}

/// A published GitHub release, reduced to what PortPilot shows.
struct ReleaseInfo: Codable, Equatable, Sendable {
    /// Normalized version from the tag, e.g. "1.2.0" for tag "v1.2.0".
    let version: String
    let tagName: String
    let name: String?
    /// Release notes (Markdown), possibly long.
    let notes: String?
    /// The release page on GitHub.
    let pageURL: URL
    /// The first .dmg asset, if the release has one.
    let downloadURL: URL?
    let publishedAt: Date?

    /// What "Download" opens: the disk image when there is one, else the release page.
    var downloadOrPageURL: URL { downloadURL ?? pageURL }
}

/// Outcome of one check.
enum UpdateCheckResult: Equatable, Sendable {
    case updateAvailable(ReleaseInfo)
    /// The latest release is not newer than this build (or is a draft, a prerelease or has a malformed tag).
    case upToDate(latest: String?)
    /// The repository has no published release yet (GitHub answers 404).
    case noReleases
    case failed(String)

    /// The text shown after a manual check, e.g. "You’re up to date (1.0.0)".
    func message(currentVersion: String) -> String {
        switch self {
        case .updateAvailable(let release): return "PortPilot \(release.version) is available"
        case .upToDate: return "You’re up to date (\(currentVersion))"
        case .noReleases: return "You’re up to date (\(currentVersion)). No releases published yet."
        case .failed(let reason): return "Couldn’t check for updates: \(reason)"
        }
    }

    /// True when GitHub gave a definite answer (worth remembering as "checked"), false for errors.
    var isConclusive: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// Asks GitHub for the latest release. Thread-safe; `check()` runs off the main thread.
final class UpdateChecker: @unchecked Sendable {
    /// Sends one request; injectable so tests never touch the network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.github.com/repos/Shayan5422/PortPilot/releases/latest")!
    static let timeout: TimeInterval = 10
    /// Release JSON is a few KB; anything far larger is not what we asked for.
    static let maxResponseBytes = 2_000_000

    private let currentVersion: String
    private let transport: Transport

    init(currentVersion: String = AppInfo.version, transport: Transport? = nil) {
        self.currentVersion = currentVersion
        self.transport = transport ?? UpdateChecker.urlSessionTransport()
    }

    /// The GET request: JSON media type, `User-Agent: PortPilot/<version>`, no cookies, no cache.
    static func request(currentVersion: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PortPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Fetches and evaluates the latest release. Never throws: failures come back as `.failed`.
    func check() async -> UpdateCheckResult {
        do {
            let (data, response) = try await transport(Self.request(currentVersion: currentVersion))
            guard let http = response as? HTTPURLResponse else { return .failed("unexpected response") }
            return Self.evaluate(status: http.statusCode, data: data, currentVersion: currentVersion)
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Pure: turns an HTTP status and body into a result.
    static func evaluate(status: Int, data: Data, currentVersion: String) -> UpdateCheckResult {
        switch status {
        case 200:
            guard data.count <= maxResponseBytes, let release = parseLatestRelease(data) else {
                // Drafts, prereleases and malformed tags are never offered.
                return .upToDate(latest: nil)
            }
            return AppVersion.isNewer(release.version, than: currentVersion)
                ? .updateAvailable(release) : .upToDate(latest: release.version)
        case 404:
            return .noReleases
        case 403, 429:
            return .failed("GitHub’s rate limit was reached. Try again later.")
        case 500...599:
            return .failed("GitHub isn’t responding right now. Try again later.")
        default:
            return .failed("unexpected response (HTTP \(status))")
        }
    }

    /// Parses GitHub's release JSON. nil for drafts, prereleases, malformed tags or a missing release page.
    static func parseLatestRelease(_ data: Data) -> ReleaseInfo? {
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = AppVersion.normalized(release.tagName) else { return nil }
        let pageURL = safeURL(release.htmlURL) ?? AppInfo.releasesURL
        let dmg = release.assets?.first { asset in
            (asset.name ?? asset.browserDownloadURL ?? "").lowercased().hasSuffix(".dmg")
        }
        return ReleaseInfo(version: version,
                           tagName: release.tagName,
                           name: release.name.flatMap { $0.isEmpty ? nil : $0 },
                           notes: release.body.flatMap { $0.isEmpty ? nil : $0 },
                           pageURL: pageURL,
                           downloadURL: safeURL(dmg?.browserDownloadURL),
                           publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// Only https links are opened from a response.
    private static func safeURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil
        else { return nil }
        return url
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "you’re offline."
        case .timedOut:
            return "GitHub didn’t respond in time."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "couldn’t reach GitHub."
        default:
            return urlError.localizedDescription
        }
    }

    /// An ephemeral session: no cookies, no URL cache, no credential storage, 10 s timeouts.
    private static func urlSessionTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        return { request in try await session.data(for: request) }
    }

    /// The fields of https://docs.github.com/rest/releases/releases#get-the-latest-release we use.
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String?
        let name: String?
        let body: String?
        let publishedAt: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String?
            let browserDownloadURL: String?

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name, body, draft, prerelease, assets
            case publishedAt = "published_at"
        }
    }
}
