# Contributing to PortPilot

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Build from source

Requirements: macOS 14+, Xcode 16+ (Xcode 26+ recommended), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/Shayan5422/PortPilot.git
cd PortPilot
xcodegen generate
open PortPilot.xcodeproj
```

`PortPilot.xcodeproj` is generated from `project.yml` — edit `project.yml`, not the project file.

Useful scripts:

| Script | What it does |
| --- | --- |
| `scripts/build.sh [--test]` | Release build into `dist/PortPilot.app` (ad-hoc signed) |
| `scripts/install.sh` | Builds and installs into `~/Applications` with the login agent |
| `scripts/uninstall.sh` | Removes the app and its login agent |
| `scripts/release.sh` | Signed + notarized `dist/PortPilot-<version>.dmg` (needs a Developer ID) |
| `swift scripts/make-brand-assets.swift` | Regenerates the app icon, logo and DMG artwork from `Design/logo.png` |

Run the tests with:

```bash
xcodebuild -project PortPilot.xcodeproj -scheme PortPilot -destination "platform=macOS" test
```

## Headless modes (handy for debugging)

```bash
PortPilot.app/Contents/MacOS/PortPilot --dump            # JSON of everything PortPilot sees
PortPilot.app/Contents/MacOS/PortPilot --plan <pid>      # what Stop would signal (sends nothing)
PortPilot.app/Contents/MacOS/PortPilot --snapshot out.png [--dark]
```

## Ground rules

- **Safety first.** Any change to `KillPlanner`, `ProcessKiller` or `Classifier.isBoundaryProcess` needs a test
  in `PortPilotTests/KillPlannerTests.swift` showing what is and isn't signalled.
- Keep the scan cheap: it runs every few seconds, forever. No subprocess per process.
- Match the surrounding style; keep comments for the non-obvious "why".
- One topic per pull request, with a short description of what changed and how you tested it.
