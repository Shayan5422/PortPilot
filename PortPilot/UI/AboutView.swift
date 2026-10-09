import SwiftUI

/// About, shown in place of the list like Settings (sheets and separate windows would close the menu bar panel):
/// icon, version, credits, links, the license and "Check for Updates…".
struct AboutView: View {
    let store: AppStore
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("About")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Back (Esc)")
            }

            identity

            SettingsSection(title: "Made by \(AppInfo.author)") {
                HStack(spacing: 6) {
                    LinkPill(title: "Website", systemImage: "globe", url: AppInfo.websiteURL)
                    LinkPill(title: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: AppInfo.githubURL)
                    LinkPill(title: "LinkedIn", systemImage: "person.crop.square", url: AppInfo.linkedInURL)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            SettingsSection(title: "Project") {
                LinkRow(title: "Source code", systemImage: "curlybraces", url: AppInfo.repositoryURL)
                LinkRow(title: "Report an issue", systemImage: "exclamationmark.bubble", url: AppInfo.issuesURL)
                LinkRow(title: "Release notes", systemImage: "doc.text", url: AppInfo.releasesURL)
                ActionRow(title: "Show Welcome Guide", systemImage: "hand.wave", showsDivider: false) {
                    WelcomeWindowController.show(store: store)
                }
            }

            SettingsSection(title: "Updates") {
                UpdateStatusRow(updates: store.updates)
            }

            HStack(spacing: 4) {
                Button(AppInfo.license) { AppInfo.open(AppInfo.licenseURL) }
                    .buttonStyle(.link)
                    .help(AppInfo.licenseURL.absoluteString)
                Text(verbatim: "·").accessibilityHidden(true)
                Text(AppInfo.copyright)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var identity: some View {
        HStack(spacing: 14) {
            AppGlyph(size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppInfo.name)
                    .font(.system(size: 20, weight: .bold))
                Text(AppInfo.versionLine())
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(AppInfo.tagline)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Update status

/// "Check for Updates…" with the current state: up to date, checking, an update to download, or an error.
struct UpdateStatusRow: View {
    let updates: UpdateController

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(updates.lastCheckFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let release = updates.availableUpdate {
                Button("Download") { updates.download(release) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(release.downloadOrPageURL.absoluteString)
            } else {
                if updates.isChecking {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Checking for updates")
                }
                Button("Check for Updates…") { updates.checkNow() }
                    .controlSize(.small)
                    .disabled(updates.isChecking)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var title: String {
        if let release = updates.availableUpdate { return "PortPilot \(release.version) is available" }
        return "PortPilot \(updates.currentVersion)"
    }

    private var detail: String {
        if updates.availableUpdate != nil { return "You have \(updates.currentVersion)." }
        if updates.isChecking { return "Checking for updates…" }
        return updates.statusMessage ?? "Downloads come from GitHub Releases. Nothing installs on its own."
    }

    private var symbol: String {
        if updates.availableUpdate != nil { return "arrow.down.circle.fill" }
        if updates.lastCheckFailed { return "exclamationmark.triangle.fill" }
        if case .finished = updates.phase { return "checkmark.circle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private var tint: Color {
        if updates.availableUpdate != nil { return .accentColor }
        if updates.lastCheckFailed { return .orange }
        if case .finished = updates.phase { return .green }
        return .secondary
    }
}

// MARK: - Building blocks

/// Small capsule link button (Website / GitHub / LinkedIn).
private struct LinkPill: View {
    let title: String
    let systemImage: String
    let url: URL

    var body: some View {
        Button {
            AppInfo.open(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 7, padding: EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)))
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chipFill))
        .help(url.absoluteString)
        .accessibilityLabel(title)
        .accessibilityHint("Opens \(url.host ?? "the link") in your browser")
    }
}

/// A full-width row that opens a link: icon, title, ↗.
private struct LinkRow: View {
    let title: String
    let systemImage: String
    let url: URL
    var showsDivider = true

    var body: some View {
        ActionRow(title: title, systemImage: systemImage, trailingSymbol: "arrow.up.right",
                  help: url.absoluteString, showsDivider: showsDivider) {
            AppInfo.open(url)
        }
    }
}

/// A full-width button row inside a settings card.
private struct ActionRow: View {
    let title: String
    let systemImage: String
    var trailingSymbol = "chevron.right"
    var help: String? = nil
    var showsDivider = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 12.5))
                    Spacer(minLength: 8)
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: 0, padding: EdgeInsets()))
            .help(help ?? title)
            .accessibilityLabel(title)

            if showsDivider {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 42)
            }
        }
    }
}

// MARK: - Header glyph

/// The app glyph in the panel header: opens About, and carries an accent dot while an update is available.
struct HeaderGlyphButton: View {
    let updates: UpdateController
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        let update = updates.availableUpdate
        Button(action: action) {
            AppGlyph(size: size)
                .overlay(alignment: .topTrailing) {
                    if update != nil {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Theme.floatingBackground, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 8, padding: EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)))
        .help(update.map { "About PortPilot — \($0.version) is available" } ?? "About PortPilot")
        .accessibilityLabel(update == nil ? "About PortPilot" : "About PortPilot, update available")
    }
}
