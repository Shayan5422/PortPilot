# PortPilot

A native macOS menu bar app that shows which ports are open on your Mac, which project folder
each one belongs to, how much CPU and memory it uses, and lets you stop it with one click. That
includes servers that would otherwise come back on their own through launchd, pm2 or Docker.

![PortPilot menu bar panel](docs/screenshot.png)

<sub>Screenshot placeholder. To regenerate it from live data:
`dist/PortPilot.app/Contents/MacOS/PortPilot --snapshot docs/screenshot.png`</sub>

## Why

Dev tools land on random ports (5173, 3000, 8000, 53000…), keep running after you close the
terminal tab, and quietly eat RAM and CPU. PortPilot sits next to Wi-Fi in the menu bar, rescans
every few seconds, and answers three questions at a glance:

- **What is listening?** Every TCP port in the LISTEN state, grouped by project.
- **Where did it come from?** The project folder (git root or package manifest), the framework
  (Vite, Next.js, uvicorn…), who started it (Claude Code, Codex, Terminal, VS Code, launchd…) and
  whether something will restart it.
- **How do I get rid of it?** One click stops the whole server: `npm run dev`, its watcher and
  its workers. Nothing else is touched.

## Features

- **Live list in the menu bar.** The icon shows how many project ports are open. The scan runs
  every 3 s by default (1–30 s in Settings) and keeps running while the panel is closed, so the
  count stays current.
- **Grouped by project.** Ports are grouped by project root, so a monorepo with a frontend and an
  API shows up as one group with both ports. Sections: *Projects*, *Background Services*
  (Homebrew postgres/redis, tunnels, launchd agents) and, optionally, *Apps* and *System*.
- **Details for each group.** Framework badges, origin ("Claude Code", "Terminal"…), manager
  ("launchd · auto-start", "pm2", "Docker", "nodemon"…), a **Network** badge when the port is
  reachable from other machines, uptime, and CPU and memory for the whole process tree. Heavy
  groups are highlighted.
- **One-click Stop.** Graceful by default. ⌥-click force-kills. Expand a group to see each
  process, the exact stop plan, and a per-process Stop button.
- **Stop & Disable Auto-Start** for anything launchd, pm2 or Docker would restart.
- **Startup Items.** Every non-Apple LaunchAgent, with its status, its ports and an
  enable/disable toggle.
- **Recently Stopped.** Copy the command or **Relaunch** a server you stopped by mistake. It
  restarts with its original arguments, environment and working directory.
- **Shortcuts:** open `http://localhost:PORT`, Reveal in Finder, Open in Terminal, Open in your
  editor (Cursor, VS Code, Zed or Xcode), copy the URL, port, PIDs or command, and hide items you
  don't care about.
- **Optional notifications** when a new port opens.
- **Light and dark mode** with a native look. Everything happens inside the panel.

## Requirements

- macOS 14 Sonoma or later. The Release build is universal (Apple Silicon and Intel). It is
  developed on Apple Silicon.
- To build: Xcode 15 or later (developed with Xcode 27) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):
  `brew install xcodegen`.

## Install

```sh
git clone <this repo> PortPilot && cd PortPilot
./scripts/install.sh
```

`install.sh` does the following:

1. Builds a Release copy (`scripts/build.sh`: `xcodegen generate` + `xcodebuild`, ad-hoc
   signed) into `dist/PortPilot.app`. Pass `--no-build` to reuse an existing build.
2. Quits a running PortPilot gracefully (AppleScript `quit`, falling back to `pkill -x PortPilot`
   for your user only) and unloads the previous LaunchAgent.
3. Copies the app to `~/Applications/PortPilot.app` and clears the quarantine flag.
4. Writes `~/Library/LaunchAgents/app.portpilot.agent.plist`, then runs `launchctl enable` and
   `launchctl bootstrap gui/$UID`. That starts the app right away.
5. Checks that the process is running.

macOS may show a **"Background Items Added"** notification. That notification is expected.

To build without installing:

```sh
./scripts/build.sh          # → dist/PortPilot.app
./scripts/build.sh --test   # run the unit tests first
```

Full build logs are written to `build/xcodebuild-*.log`.

## How auto-start works

PortPilot is started by a per-user **LaunchAgent**, not by a login item inside the app:

```xml
<key>Label</key>                  <string>app.portpilot.agent</string>
<key>ProgramArguments</key>       <array><string>~/Applications/PortPilot.app/Contents/MacOS/PortPilot</string></array>
<key>RunAtLoad</key>              <true/>
<key>KeepAlive</key>              <dict><key>SuccessfulExit</key><false/></dict>
<key>ProcessType</key>            <string>Interactive</string>
<key>LimitLoadToSessionType</key> <string>Aqua</string>
<key>StandardOutPath</key>        <string>~/Library/Logs/PortPilot/portpilot.log</string>
<key>StandardErrorPath</key>      <string>~/Library/Logs/PortPilot/portpilot.log</string>
```

(The real file contains absolute paths. launchd does not expand `~`.)

- **RunAtLoad**: PortPilot starts at every login, so it is back after a restart.
- **KeepAlive / SuccessfulExit = false**: if PortPilot crashes (non-zero exit or a signal),
  launchd starts it again. If you choose **Quit**, it exits cleanly and stays closed until your
  next login.
- **Settings → Launch at login** turns this off: it runs `launchctl disable` and removes the plist.
  Turning it back on rewrites the plist. If you move the app, it repairs the plist path the next
  time it starts.

## How "Stop" decides what to kill

The goal is to stop the whole server you started, never your terminal, your editor or your AI
agent session. For the process that owns the port, PortPilot builds a **stop plan**:

1. **Find the root of the launch.** Starting at the listening process, it walks up the parent
   chain. It keeps going while the parent is one of these:
   - a *runner*: `npm`/`pnpm`/`yarn`/`bun run`, `npx`, `nodemon`, `tsx watch`, `concurrently`,
     `turbo`, `nx`, `make`, `cargo run`/`cargo watch`, `go run`, `air`, `poetry run`, `uv run`,
     `pipenv run`, `bundle exec`, `foreman`/`overmind`/`honcho`…
   - a `sh -c "…"` wrapper whose own parent is a runner
   - another process from the same project folder that is not a shell

   It stops at **boundary processes**: interactive shells, terminal apps, IDEs, Claude Code or
   Codex, tmux, launchd (pid 1), and anything owned by another user.
2. **Targets** = that root plus all its descendants (esbuild, workers, reloaders…), signalled
   children first. PortPilot never targets itself, pid ≤ 1, boundary processes, or other users'
   processes. The one exception is the listener itself when it belongs to another user. In that
   case, Stop asks for your administrator password through the standard macOS prompt.
3. **Signals.** Stop sends `SIGTERM` and waits for the graceful timeout (3 s by default, 1–10 s
   in Settings). Survivors then get `SIGKILL`. If the root leads its own process group and that
   group contains no boundary process, the group is signalled too. ⌥-click skips straight to
   `SIGKILL`.
4. **Safety.** Right before each signal, PortPilot checks the PID's start time again. A PID that
   the kernel has reused for a different process is never hit.

Expand a group to see the plan ("npm run dev (pid 1200)", "node vite (pid 1201)"…) before you
press Stop. You can also print it from a terminal with `--plan <pid>`. Warnings are shown when
something will restart the server, when it is exposed to the network, or when the plan also stops
other listeners.

## Cancelling auto-start (launchd, pm2, Docker)

Some servers come back right after you kill them, because a manager restarts them. PortPilot
detects the manager and shows an orange **auto-start** badge. Use **Stop & Disable Auto-Start**
from the group's ⋯ menu:

| Managed by | Stop | Stop & Disable Auto-Start |
| --- | --- | --- |
| **launchd** (LaunchAgents, `brew services`) | `launchctl bootout gui/$UID/<label>`: stopped until next login | bootout + `launchctl disable`: stays off across logins. The plist is kept; re-enable it under *Startup Items*. |
| **pm2** | `pm2 stop <id>` | `pm2 delete <id>` + `pm2 save --force`, so `pm2 resurrect` won't bring it back |
| **Docker** | `docker stop <id>` | `docker update --restart=no <id>` + `docker stop` |
| **Watchers** (nodemon, `tsx watch`, `uvicorn --reload`, cargo-watch…) | The watcher is part of the stop plan, so a normal Stop is enough | n/a |

PortPilot only runs `pm2` commands when a pm2 daemon is already running (any `pm2` command
would otherwise start one), and only runs `docker` when a Docker backend owns a listening port.

The **Startup Items** section lists every non-Apple LaunchAgent in `~/Library/LaunchAgents` (and,
read-only, `/Library/LaunchAgents`) with a running / loaded / disabled / failed status dot and a
toggle. If PortPilot shows a "came back" banner after a Stop, it offers the disable action there
as well.

## Privacy

- **No network access.** PortPilot makes no outgoing connections. Clicking a port chip opens
  `http://localhost:PORT` in your browser. That is the only network-related action.
- **No telemetry, analytics or accounts.**
- Everything is read locally: the process table through `sysctl`/`libproc`, plus `launchctl`, and
  `pm2`/`docker` only when they are relevant (see above).
- Recently stopped commands can contain secrets in their environment, so they are kept **in
  memory only** and are never written to disk.
- Settings live in `UserDefaults` (`app.portpilot.PortPilot`). The app's own output and relaunched
  servers' output go to `~/Library/Logs/PortPilot/`.
- The app is not sandboxed. It has to inspect and signal other processes, and that is not
  possible inside the App Sandbox.

## Command-line modes

The app binary also has headless modes for scripting and debugging. They print a result and exit
without starting the UI:

```sh
PP=~/Applications/PortPilot.app/Contents/MacOS/PortPilot

"$PP" --dump                      # JSON of the grouped scan (ports, projects, processes, stop plans)
"$PP" --plan 12345                # what Stop would signal for the listener with pid 12345; nothing is sent
"$PP" --snapshot out.png          # render the panel with live data to a PNG
"$PP" --snapshot out.png --dark   # …in dark mode
```

`--dump` and `--snapshot` also accept `--all`, which includes other users' and system
listeners.

## Uninstall

```sh
./scripts/uninstall.sh           # asks for confirmation
./scripts/uninstall.sh -y        # no prompt
./scripts/uninstall.sh --purge   # also delete logs and preferences
```

This unloads and deletes the LaunchAgent, quits the app and removes
`~/Applications/PortPilot.app`. Your clone, including `build/` and `dist/`, is left alone.

## Troubleshooting

- **No icon in the menu bar.** On MacBooks with a notch, menu bar items can be hidden behind it
  when the bar is full. Quit a few menu bar apps, or ⌘-drag icons to make room. To check that
  PortPilot is running:
  ```sh
  pgrep -x PortPilot
  launchctl print gui/$UID/app.portpilot.agent | grep -E 'state|last exit'
  tail -n 50 ~/Library/Logs/PortPilot/portpilot.log
  ```
- **It doesn't start at login, or `install.sh` says bootstrap failed.** Open *System Settings →
  General → Login Items & Extensions → Allow in the Background* and make sure PortPilot (it may be
  listed under its executable name) is switched on. Then run `./scripts/install.sh --no-build`.
- **A server keeps coming back after Stop.** Something outside its process tree restarts it. Look
  for the auto-start badge and use **Stop & Disable Auto-Start**, or check *Startup Items*. Run
  `--plan <pid>` to see what Stop targets and which manager was detected.
- **A port is missing.** GUI apps and system processes are hidden by default. Turn on *Show Apps*
  / *Show System* in Settings, or click "N hidden · Show" if you hid it yourself.
- **"Operation not permitted" when stopping.** The process belongs to another user, usually
  root. Stop offers an administrator prompt for the listener itself.
- **The build fails with "xcodebuild requires Xcode".** Install Xcode, then run
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and
  `sudo xcodebuild -license accept` once. If XcodeGen is missing: `brew install xcodegen`.
- **"PortPilot is damaged and can't be opened"** (after copying the app from another Mac):
  `xattr -dr com.apple.quarantine ~/Applications/PortPilot.app`.

## Project layout

```
PortPilot/App/        entry point (MenuBarExtra), AppStore (state + actions), CLI modes
PortPilot/Core/       models, process table / socket scanning, project resolver, classifier
PortPilot/Control/    launchd / pm2 / docker services, kill planner, process killer, relauncher,
                      login item (LaunchAgent) manager, notifications
PortPilot/UI/         SwiftUI panel, rows, settings, snapshot renderer
PortPilot/Resources/  Info.plist, Assets.xcassets (app icon, accent colour)
PortPilotTests/       unit tests for the pure logic
scripts/              build.sh, install.sh, uninstall.sh, make-icon.swift
docs/SPEC.md          implementation spec
```

`PortPilot.xcodeproj` is generated from `project.yml`. Run `xcodegen generate` and open it in
Xcode. The app icon is drawn in code: `swift scripts/make-icon.swift` regenerates every size in
`PortPilot/Resources/Assets.xcassets/AppIcon.appiconset`, and `--preview sheet.png` also writes a
contact sheet.

---

<div dir="rtl">

## راهنمای سریع (فارسی)

PortPilot یک برنامهٔ نوار منوی مک است. هر چند ثانیه پورت‌های باز را بررسی می‌کند، نشان می‌دهد هر پورت مال کدام پروژه یا پوشه است و چقدر CPU و رم مصرف می‌کند، و با یک کلیک آن را می‌بندد.

**نصب**

1. اگر XcodeGen ندارید: `brew install xcodegen`
2. در پوشهٔ پروژه این را اجرا کنید: `./scripts/install.sh`
3. آیکون PortPilot کنار Wi-Fi در نوار منو ظاهر می‌شود.

**اجرای خودکار:** نصب‌کننده یک LaunchAgent می‌سازد. برنامه بعد از هر ورود به سیستم و هر ری‌استارت خودش اجرا می‌شود. اگر کرش کند دوباره باز می‌شود، ولی اگر خودتان Quit کنید تا ورود بعدی بسته می‌ماند. برای خاموش کردنش در تنظیمات برنامه گزینهٔ Launch at login را بردارید.

**بستن پورت:** روی دکمهٔ ✕ کنار هر ردیف کلیک کنید. با ⌥ + کلیک، بستن اجباری انجام می‌شود (SIGKILL). فقط خودِ سرور و پروسه‌های زیرمجموعه‌اش بسته می‌شوند. ترمینال، ادیتور و Claude Code دست نمی‌خورند.

**لغو اجرای خودکار:** بعضی سرویس‌ها با launchd، pm2 یا Docker دوباره بالا می‌آیند. برای آن‌ها از منوی «⋯» گزینهٔ **Stop & Disable Auto-Start** را بزنید، یا در بخش **Startup Items** آن مورد را غیرفعال کنید.

**حریم خصوصی:** برنامه به اینترنت وصل نمی‌شود و هیچ داده‌ای ارسال نمی‌کند.

**حذف برنامه:** `./scripts/uninstall.sh`

</div>
