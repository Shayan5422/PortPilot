# Changelog

All notable changes to PortPilot are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-10-09

First public release.

### Added
- Menu bar app that lists every listening TCP port and groups it by project folder, background service, app or system process.
- One-click Stop that ends the whole dev-server tree (npm → node → esbuild …) without touching your terminal, IDE or AI agent.
- Auto-start awareness: launchd agents, `brew services`, pm2 and Docker restart policies, with **Stop & Disable Auto-Start**.
- Startup Items: switch any user LaunchAgent on or off.
- CPU and memory per project, with heavy-usage highlighting.
- Recently Stopped list with Undo / Relaunch and Copy Command. Undo restarts every server a Stop ended and only reports
  success once they listen on their ports again.
- Apps are asked to quit the way ⌘Q does, so they can ask to save; Stop never force-quits an app or a macOS service.
- "Still running · no open port": tools that closed their ports but left processes running, with one-click Stop.
- Launch at login with automatic restart after a crash.
- Optional notifications when a project opens a new port.
- About page and a once-a-day update check on GitHub (can be turned off; nothing is installed automatically).
- First-launch welcome window that offers to move PortPilot to Applications and explains the macOS folder-access prompt.
- Headless `--dump`, `--plan`, `--snapshot` (with `--demo`, `--settings`, `--about` and `--welcome`) and
  `--check-updates` modes.
