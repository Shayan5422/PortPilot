# Security Policy

PortPilot inspects and signals processes on your Mac, so its safety rules matter.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
[private vulnerability reporting](https://github.com/Shayan5422/PortPilot/security/advisories/new)
instead. Include the macOS version, the PortPilot version, and steps to reproduce.

You can expect an acknowledgement within a few days.

## Scope

Especially interesting:

- A Stop action that signals a process outside the plan shown in the panel (for example a terminal,
  an IDE, an AI agent CLI or a process owned by another user).
- Anything that lets another local process make PortPilot run commands.
- Privilege escalation through the optional administrator prompt.

## Design notes

- PortPilot makes no network requests except the optional update check (GitHub Releases API).
- It never sends telemetry and stores settings only in its own `UserDefaults` domain.
- Environment variables captured for "Relaunch" stay in memory and are never written to disk.
