import SwiftUI

/// Calm, persistent notices at the top of the list (not transient banners): an available update, and a scan
/// waiting on a macOS folder-access prompt. Renders nothing when there is nothing to say.
struct PanelNotices: View {
    let store: AppStore

    var body: some View {
        let waiting = store.folderAccess.waitingMessage
        let update = store.updates.availableUpdate
        if waiting != nil || update != nil {
            VStack(spacing: 6) {
                if let waiting {
                    FolderAccessNotice(message: waiting)
                }
                if let update {
                    UpdateNotice(release: update, updates: store.updates)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 4)
        }
    }
}

/// "PortPilot 1.1.0 is available" with Download, Release Notes and Skip This Version.
struct UpdateNotice: View {
    let release: ReleaseInfo
    let updates: UpdateController

    var body: some View {
        NoticeCard(tint: .accentColor) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "PortPilot \(release.version) is available")
                        .font(.system(size: 12.5, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(verbatim: "You have \(updates.currentVersion).")
                            .foregroundStyle(.secondary)
                        Button("Release Notes") { updates.openReleaseNotes(release) }
                            .help(release.pageURL.absoluteString)
                        Text(verbatim: "·")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Button("Skip This Version") { updates.skip(release) }
                            .help("Hide this until a newer version comes out")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                Spacer(minLength: 6)
                Button("Download") { updates.download(release) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(release.downloadURL == nil ? "Open the release page" : "Download the disk image")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Waiting for access to Downloads. Click Allow in the macOS prompt so PortPilot can name your projects."
struct FolderAccessNotice: View {
    let message: String

    var body: some View {
        NoticeCard(tint: .blue) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 15))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tinted rounded card used by the notices.
private struct NoticeCard<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tint.opacity(0.09)))
            .overlay(shape.strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}
