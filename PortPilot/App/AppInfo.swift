import AppKit
import Foundation

/// Version, credits and project links shown in About, the welcome window and the update check.
/// Everything here is public information; nothing identifies the user or the machine.
enum AppInfo {
    static let name = "PortPilot"
    static let tagline = "See every port your projects open — and close them in one click."
    static let author = "Shayan Hashemi"
    static let license = "MIT License"
    static let copyright = "© 2026 Shayan Hashemi"

    static let websiteURL = URL(string: "https://www.shhshm.eu/")!
    static let githubURL = URL(string: "https://github.com/Shayan5422")!
    static let linkedInURL = URL(string: "https://www.linkedin.com/in/shhshm/")!
    static let repositoryURL = URL(string: "https://github.com/Shayan5422/PortPilot")!
    static let issuesURL = URL(string: "https://github.com/Shayan5422/PortPilot/issues")!
    static let releasesURL = URL(string: "https://github.com/Shayan5422/PortPilot/releases")!
    static let licenseURL = URL(string: "https://github.com/Shayan5422/PortPilot/blob/main/LICENSE")!
    /// System Settings › Privacy & Security › Files & Folders.
    static let filesAndFoldersPrivacyURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// CFBundleShortVersionString (MARKETING_VERSION in project.yml), e.g. "1.0.0".
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1.0.0"
    }

    /// CFBundleVersion (CURRENT_PROJECT_VERSION in project.yml), e.g. "1".
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    /// "Version 1.0.0 (1)"; the build number is left out when it is missing or equal to the version.
    static func versionLine(version: String = version, build: String = build) -> String {
        guard !build.isEmpty, build != version else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    /// Opens a link in the default browser (or System Settings for x-apple.systempreferences: links).
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The UserDefaults calls the update check and folder-access tracking make. UserDefaults conforms as is; tests pass
/// an in-memory store, so they never write preference files.
protocol PreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStore {}
