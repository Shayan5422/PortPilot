import Foundation
import Observation

/// What macOS decided about one privacy-protected folder (Downloads, Documents, Desktop, a volume...).
enum FolderAccessState: Equatable, Sendable {
    /// Not asked yet. Reading the folder now would show the macOS prompt, so PortPilot doesn't.
    case notAsked
    /// Waiting on the macOS prompt.
    case asking
    case allowed
    case denied
    /// The folder doesn't exist (nothing to ask).
    case missing
}

/// Pure helpers for folder-access prompts.
enum FolderAccess {
    /// The folders the welcome window asks about, in prompt order.
    static func standardFolders(home: String = NSHomeDirectory()) -> [String] {
        ["Downloads", "Documents", "Desktop"].map { (home as NSString).appendingPathComponent($0) }
    }

    /// Short name for a protected folder: "Downloads", "iCloud Drive", "Google Drive", or a volume's name.
    static func displayName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if name == "Mobile Documents" { return "iCloud Drive" }
        if (path as NSString).deletingLastPathComponent.hasSuffix("/Library/CloudStorage") {
            // "GoogleDrive-name@example.com" → "Google Drive": never show the account part.
            let provider = name.split(separator: "-", maxSplits: 1).first.map(String.init) ?? name
            switch provider {
            case "GoogleDrive": return "Google Drive"
            case "OneDrive": return "OneDrive"
            default: return provider
            }
        }
        return name.isEmpty ? path : name
    }

    /// "Downloads", "Downloads and Desktop", "Downloads, Documents and Desktop".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The notice shown while a scan waits on a prompt; nil when nothing is waiting.
    static func waitingMessage(for folders: [String]) -> String? {
        guard !folders.isEmpty else { return nil }
        return "Waiting for access to \(list(folders.map(displayName))). Click Allow in the macOS prompt so "
            + "PortPilot can name your projects."
    }

    /// Classifies the outcome of reading a folder's listing.
    static func state(forReadError error: Error?) -> FolderAccessState {
        guard let error else { return .allowed }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError: return .denied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .missing
            default: break
            }
        }
        let posix = (nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
        if let posix, posix.domain == NSPOSIXErrorDomain {
            if posix.code == Int(EPERM) || posix.code == Int(EACCES) { return .denied }
            if posix.code == Int(ENOENT) || posix.code == Int(ENOTDIR) { return .missing }
        }
        // Anything else (I/O error on a flaky volume...) is not a privacy decision.
        return .allowed
    }

    /// Lists the folder, which is what makes macOS show its prompt when the decision is still open.
    /// Blocks until the user answers that prompt: never call on the main thread.
    static func probe(_ path: String) -> FolderAccessState {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return .allowed
        } catch {
            return state(forReadError: error)
        }
    }
}

/// Folder-access state for the UI: the "Waiting for access to Downloads" notice (from the scan), the welcome
/// window's deliberate request, and Settings' "Not allowed" rows.
///
/// PortPilot asks once, at a moment the user expects (the welcome window), and never in a loop: a folder is only
/// read again to refresh its state once it has been asked about, when reading it can no longer show a prompt.
/// Inert until `activate()` (live app only), so previews, snapshots and tests never read real folders.
@MainActor
@Observable
final class FolderAccessController {
    enum Keys {
        /// Folders PortPilot has asked about (through the welcome window, or a scan that waited on a prompt).
        static let asked = "folderAccess.asked"
        static let all = [asked]
    }

    /// Folders a scan is waiting on right now (a macOS prompt is probably on screen).
    private(set) var awaiting: [String] = []
    /// Last known state per folder path.
    private(set) var states: [String: FolderAccessState] = [:]
    /// The welcome window's request is running.
    private(set) var isRequesting = false

    @ObservationIgnored private let defaults: PreferenceStore
    @ObservationIgnored private let probe: @Sendable (String) -> FolderAccessState
    @ObservationIgnored private let queue = DispatchQueue(label: "eu.shhshm.PortPilot.folder-access", qos: .utility)
    @ObservationIgnored private(set) var isActive = false

    init(defaults: PreferenceStore = UserDefaults.standard,
         probe: @escaping @Sendable (String) -> FolderAccessState = { FolderAccess.probe($0) }) {
        self.defaults = defaults
        self.probe = probe
    }

    /// Folders macOS said no to, in display order.
    var denied: [String] {
        states.filter { $0.value == .denied }.map(\.key).sorted()
    }

    /// "Waiting for access to Downloads…" while a scan waits on a prompt, else nil.
    var waitingMessage: String? { FolderAccess.waitingMessage(for: awaiting) }

    func state(of folder: String) -> FolderAccessState {
        states[folder] ?? .notAsked
    }

    /// Live app only: enables refreshing and requesting, and re-checks folders asked about before.
    func activate() {
        guard !isActive else { return }
        isActive = true
        refresh()
    }

    /// Called after every scan with `ScanOutput.foldersAwaitingAccess`. Cheap when nothing changed.
    func scanReported(awaiting folders: [String]) {
        guard folders != awaiting else { return }
        let finished = Set(awaiting).subtracting(folders)
        awaiting = folders
        for folder in folders where states[folder] != .denied { states[folder] = .asking }
        markAsked(folders)
        // The prompt was answered: find out how.
        if !finished.isEmpty { refresh(only: Array(finished)) }
    }

    /// Re-reads folders that were asked about before (reading them can't prompt again). Off the main thread.
    func refresh() {
        refresh(only: askedFolders)
    }

    /// The welcome window's "Continue": asks for each folder in turn, one macOS prompt at a time, on a background
    /// queue. Folders that don't exist are skipped. `completion` runs on the main actor when all are answered.
    func requestAccess(to folders: [String] = FolderAccess.standardFolders(), completion: (() -> Void)? = nil) {
        guard isActive, !isRequesting else { return }
        isRequesting = true
        let probe = self.probe
        queue.async { [weak self] in
            for folder in folders {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue
                else {
                    Self.onMain { self?.record(folder, .missing, asked: false) }
                    continue
                }
                Self.onMain { self?.states[folder] = .asking }
                let state = probe(folder)
                Self.onMain { self?.record(folder, state, asked: true) }
            }
            Self.onMain {
                self?.isRequesting = false
                completion?()
            }
        }
    }

    /// System Settings › Privacy & Security › Files & Folders.
    func openPrivacySettings() {
        AppInfo.open(AppInfo.filesAndFoldersPrivacyURL)
    }

    /// Sets a state directly (previews, snapshots and UI tests).
    func showForPreview(_ states: [String: FolderAccessState], awaiting: [String] = []) {
        self.states = states
        self.awaiting = awaiting
    }

    // MARK: Private

    /// Runs on the main actor in submission order (Task hops don't guarantee order).
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    private var askedFolders: [String] {
        defaults.object(forKey: Keys.asked) as? [String] ?? []
    }

    private func markAsked(_ folders: [String]) {
        guard isActive else { return }
        let known = askedFolders
        let added = folders.filter { !known.contains($0) }
        guard !added.isEmpty else { return }
        defaults.set(known + added, forKey: Keys.asked)
    }

    private func record(_ folder: String, _ state: FolderAccessState, asked: Bool) {
        states[folder] = state
        if asked { markAsked([folder]) }
    }

    private func refresh(only folders: [String]) {
        guard isActive, !folders.isEmpty else { return }
        let probe = self.probe
        let asked = Set(askedFolders)
        // Never read a folder nobody asked about: that is what would show the prompt.
        let safe = folders.filter { asked.contains($0) }
        guard !safe.isEmpty else { return }
        queue.async { [weak self] in
            for folder in safe {
                let state = probe(folder)
                Self.onMain {
                    guard let self, !self.awaiting.contains(folder) else { return }
                    self.states[folder] = state
                }
            }
        }
    }
}
