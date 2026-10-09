import Foundation

/// How a Stop control behaves for what it would end. Pure (no UI, no system calls), so it is unit tested.
///
/// Projects and background services stop with one click — that is the app's point. Apps, macOS services and
/// other users' processes need a second click: stopping them can close an app without saving, break a system
/// feature, or raise an administrator password prompt, and a search query can put them right next to the
/// user's own projects. launchd itself (pid 1) can't be stopped, so no Stop control is shown for it.
enum StopSafety: Equatable {
    case oneClick
    case confirm(Reason)
    /// Every process is pid ≤ 1: nothing a Stop could end.
    case unavailable

    enum Reason: Equatable {
        /// A GUI app or one of its helpers (VS Code, Spotify, an IDE's language server…).
        case app
        /// Part of macOS.
        case system
        /// Owned by another user: stopping it asks for an administrator password.
        case otherUser
    }

    static func forGroup(_ group: ListenerGroup) -> StopSafety {
        evaluate(category: group.category, processes: group.processes)
    }

    static func forProcess(_ process: ListenerProcess) -> StopSafety {
        evaluate(category: process.category, processes: [process])
    }

    static func evaluate(category: ListenerCategory, processes: [ListenerProcess]) -> StopSafety {
        guard processes.contains(where: { $0.basic.pid > 1 }) else { return .unavailable }
        if processes.contains(where: \.isRestricted) { return .confirm(.otherUser) }
        switch category {
        case .app: return .confirm(.app)
        case .system: return .confirm(.system)
        case .project, .service: return .oneClick
        }
    }

    var isAvailable: Bool { self != .unavailable }

    var reason: Reason? {
        if case .confirm(let reason) = self { return reason }
        return nil
    }
}

extension StopSafety.Reason {
    /// Tooltip of an armed Stop button: what the second click will do.
    func armedHelp(title: String) -> String {
        switch self {
        case .app:
            return "\(title) is an app. Stopping it can close it without saving. Click again to stop it."
        case .system:
            return "\(title) is part of macOS. Stopping it can affect your Mac until it restarts. Click again to stop it."
        case .otherUser:
            return "\(title) belongs to another user. Click again, then enter an administrator password."
        }
    }

    /// First (disabled) line of the Stop submenu.
    var menuNote: String {
        switch self {
        case .app: return "This is an app — unsaved work may be lost."
        case .system: return "This is part of macOS."
        case .otherUser: return "Owned by another user — needs an administrator password."
        }
    }
}
