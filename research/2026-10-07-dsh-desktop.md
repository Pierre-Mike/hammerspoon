# Can a DSH plugin in DeepSeek Harness Desktop replace Hammerspoon?

Date: 2026-10-07. Short answer: no. A DSH plugin can do the headless Node half of the setup (processes, files, network, timers), but it cannot register global hotkeys, own a menu-bar item, draw HUD overlays, watch windows, or react to system events through any DSH or Desktop API. Those are the parts Hammerspoon exists for.

## Sources

- Installed CLI: `/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/`, version `0.2.0-rc.2` (`package.json`), plus the package READMEs under its `node_modules/@deepseek-ai/`.
- npm registry: `npm view @deepseek-ai/dsh versions|time|dist-tags`.
- Upstream repo [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness), default branch `master`, last push 2026-10-03. Desktop source files: [apps/desktop/README.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/README.md), [apps/desktop/package.json](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/package.json), [src/main.ts](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/main.ts), [src/tray.ts](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/tray.ts), [src/host-process.ts](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/host-process.ts), [src/keyboard.ts](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/keyboard.ts), [src/update-attention.ts](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/update-attention.ts), [src/microphone-permissions.ts](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/microphone-permissions.ts).
- GitHub releases ([dsh-v0.2.0-rc.1 notes](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.0-rc.1)).
- Web search was unavailable in this session (the DSH search tool had no `DEEPSEEK_API_KEY`), so there are no third-party announcements here. Everything comes from first-party code, npm, and GitHub.

## Does a Desktop app exist?

Yes.

- **Built on Electron.** `apps/desktop/package.json` names the package `@deepseek-ai/dsh-desktop` (version `0.2.1-alpha.1` on master) and depends on `electron ^44.0.0`. The README says: "The desktop application is an Electron shell around the complete dsh Web application."
- **Process model.** The Electron main process spawns one child with `ELECTRON_RUN_AS_NODE=1` that runs the private `dsh-desktop-host` entry (`host-process.ts:189`). The renderer loads the Web UI at `dsh-app://app/` and proxies HTTP to that Host on an OS-assigned port, not 3080.
- **History.** The first packaging commit is "feat: electron 打包" on 2026-08-28. The first GitHub release notes that mention Desktop are `dsh-v0.1.7-rc.2` (2026-09-24). The macOS DMG at `https://download.deepseek.com/desktop/dsh-latest-macos-arm64.dmg` returns HTTP 200, size 370 MB, last modified 2026-09-29, which matches `0.2.0-rc.2`.
- **macOS support.** Yes, on arm64 and x64 (Rosetta). The app is signed and notarized with hardened runtime. Windows x64 is also supported. Linux is not a Desktop target (README, "The macOS arm64 command requires Apple Silicon...").
- **Install.** Download the DMG. The app can optionally install `/usr/local/bin/dsh` through **Manage dsh Command…**. It updates itself through a mandatory-update channel.
- **Local state.** Desktop is not installed on this Mac. There is no app in `/Applications` and no `~/.dsh/profiles/desktop`. The installed CLI refuses the profile: `dsh desktop` prints `error: profile "desktop" is managed exclusively by the Electron application` (`lib/bin.js:35`).

## Versions

| Item | Value |
|---|---|
| Installed CLI | `0.2.0-rc.2` |
| npm `latest` / `next` | `0.2.0-rc.2` (2026-09-29) |
| npm `alpha` | `0.2.1-alpha.1` (2026-10-03) |
| Desktop on master | `0.2.1-alpha.1` |
| Releases | Every GitHub release since `0.1.7-rc.2` is marked prerelease. There is no stable 1.x. |

The README pins Desktop and `@deepseek-ai/dsh` to the same exact version.

## Capability table

"Plugin" means a DSH/Cordis plugin installed into the Desktop profile. Host-side plugin code runs inside the RunAsNode child. Client-side plugin code runs in the sandboxed renderer.

| Capability | Answer | API / evidence |
|---|---|---|
| Run code in the host with full Node (child processes, files, network) | **Yes** | README: "Both host and plugins execute in the same Electron Node-mode process." That process is a plain Node child (`ELECTRON_RUN_AS_NODE`) without Electron APIs. Host plugins can `require('node:child_process')`, use `fs` and `fetch`, and use helpers such as `dsh-native-command` and `ctx.subprocess`. |
| Global system-wide hotkeys (app not focused) | **No** | `dsh-client-shortcuts` (`ctx.shortcuts`) binds app-window commands only. Desktop catches keys through `webContents` `before-input-event` (`keyboard.ts:206`), which fires only when the DSH window is focused. No `globalShortcut` call exists in `apps/desktop/src`. The only workaround is spawning your own helper binary (skhd, a Swift tool) from a host plugin. |
| Menu-bar / tray icon with dynamic title and menu | **No on macOS** | `tray.ts` builds a fixed Open/Quit tray, and only on Windows (`main.ts:984-990`). macOS gets the Dock icon. Plugins have no tray API, and the Host child cannot reach Electron's `Tray`. |
| Always-on-top overlay / HUD windows | **No** | No plugin-facing `BrowserWindow` API exists. Client plugins can only render inside the app window (layout slots, toasts, sidebar panels). |
| macOS notifications | **Partial** | Desktop uses Electron `Notification` internally for update reminders (`update-attention.ts:42`). Plugins get no API for it. A host plugin can shell out to `osascript -e 'display notification ...'`. In-app toasts exist but stay inside the window. |
| Start at login, run in background with no window | **Partial** | No `setLoginItemSettings` in the source, so add it to Login Items yourself. On macOS, closing the window hides it while the Host keeps running and tasks continue (README, "Closing the window and quitting"). The process lives in the Dock, and ⌘Q asks for confirmation when tasks or reminders are active. |
| Capture microphone audio | **Partial** | The renderer can capture audio, limited to the primary `dsh-app://app` frame. The app carries `com.apple.security.device.audio-input` and a usage string, and uses `systemPreferences.askForMediaAccess` (`microphone-permissions.ts`). `dsh-experimental-voice-input-bundle` uses this path for dictation into the composer. A host plugin can also spawn a recorder such as `sox` or `ffmpeg`. macOS should attribute that to DeepSeek Harness.app as the responsible process (not verified). |
| Watch app focus / window events, move or resize windows | **No** | No API. Only possible through a spawned helper or AppleScript polling. |
| Accessibility APIs, AppleScript/osascript, URL schemes | **Partial** | No native AX bindings. `osascript` and `open <url>` run fine as child processes. The GUI-scripting parts need Accessibility/Automation grants for the DSH app. Desktop registers `dsh://open` for itself. `dsh-host-open-in-app` opens workspace folders in a fixed catalog of editors, terminals, and Git apps. |
| System events (sleep/wake, audio device change, USB/Bluetooth) | **No** | Desktop subscribes to `powerMonitor` `resume` only for its own update checks (`main.ts:918`). Nothing reaches plugins. |
| Timers / scheduling | **Yes** | Host plugins get `ctx.timeout`, `ctx.interval`, `ctx.throttle`, and `ctx.debounce` from `@cordisjs/plugin-timer`, and plain Node timers work too. `dsh-schedule` (enable `@deepseek-ai/dsh-experimental-schedule-bundle`) is something else: one-shot, daily, weekly, and cron reminders delivered as messages into an agent Session. It is for LLM tasks, not code callbacks. |
| Webhook-triggered automation | **Yes, different shape** | `dsh-webhook` `ctx.webhookRuntime.register(rule)` runs trusted code on an external event and can open an agent Session. |

## Plugin distribution and loading in Desktop

- Electron owns `$DSH_HOME/profiles/desktop` exclusively. `dsh.profile.bundles` lists the built-in bundles and then the enabled plugins. New Desktop profiles start from the shared Web template's bundles (README, "Installation ownership").
- There are two ways to install. One is the in-app Plugins page, which uses the shared plugin manager with Desktop's bundled pnpm. The other is the Desktop-installed `dsh` command: launch Desktop once, quit it fully, run `dsh plugin --profile desktop add <package>`, then reopen. The npm-installed `dsh` (the one on this machine) cannot manage the Desktop profile (`lib/bin.js:119`, `lib/plugin-*.js:11`).
- Hot reload works where the composition enables HMR. The plugin manager reports `applied` for live profiles and `restart-required` otherwise, and replacing a package always needs a process restart (`dsh-plugin-manager` README, lines 14, 67, 130). The browser-side `dsh-client-hmr` SSE path is "Web transport only" and does not apply to Electron (`dsh-client-hmr` README:118). For client-side plugin edits, expect a page reload or an app restart.
- Desktop shares product data under `$DSH_HOME` (sessions, settings, credentials) with the CLI and Web. It never shares executable packages, plugin activation, lockfiles, or `node_modules` (README design table, "State ownership"). Plugins installed in `~/.dsh/profiles/web` or `voice` do not show up in Desktop. Each one has to be installed again into the Desktop profile.

## Gaps and risks

- **Maturity.** Every release is a prerelease (`rc`/`alpha`), with releases every few days. The Desktop app is about six weeks old by code and two weeks old by release notes. Mandatory updates can replace the runtime under your plugins, and native modules may need repair after Electron's Node version changes (README, "Runtime and plugin activation", step 3).
- **Memory.** Desktop itself was not measured because it is not installed. For comparison on this machine: the `dsh --profile web` Host uses 377 MB RSS, the `dsh --profile voice` Host uses 156 MB, and Hammerspoon uses 123 MB. Desktop adds an Electron main process, a renderer, and a GPU helper on top of a comparable Host. Expect several hundred MB more than Hammerspoon.
- **The app must stay running.** Plugins live in the Host child, so quitting Desktop stops all automation. Closing the window is fine on macOS. Fatal recovery can disable all third-party plugins in one click.
- **TCC permissions.** These belong to the signed "DeepSeek Harness" app bundle, and child processes inherit that responsibility. The microphone has an entitlement and a usage string. Accessibility and Input Monitoring have no usage strings and no helpers, so any helper you spawn would make macOS prompt on behalf of DeepSeek Harness. A mandatory update that changes the signature could reset those grants. That last point is inferred, not tested.
- **Collision with `dsh web` on 3080.** None. Desktop uses an OS-assigned port and its own profile, so both can run at once.

## Not determined

- Real Desktop memory use, startup time, and TCC prompts on macOS. The app was not installed and the brief did not allow installing it.
- Whether the Web Notification API works from a client plugin in the Desktop renderer. The source shows no permission handler either way.
- Third-party announcements or blog posts from the last two weeks, because web search was unavailable.
- Whether an Electron-main extension point is planned. No implemented or proposed note in the repo tree mentions plugin access to tray, global shortcuts, or windows.

## Verdict

1. DSH Desktop exists. It is a signed Electron 44 app for macOS and Windows, first released in late September 2026, and still a prerelease (`0.2.0-rc.2`).
2. Desktop plugins run in a plain Node child with full Node access, but get no Electron APIs. There are no global hotkeys, no macOS menu-bar item, no HUD windows, no window or focus events, and no system events.
3. Those missing pieces cover the core of this Hammerspoon config (hotkeys, menu-bar status, overlays, window control), so Desktop cannot replace it.
4. A host plugin could take over the headless parts: launching STT/TTS servers, timers, HTTP calls, and `osascript`. Either keep Hammerspoon as the native front end and call DSH over HTTP, or spawn native helpers.
5. Check again if DeepSeek adds a plugin-facing main-process API (tray, `globalShortcut`, `BrowserWindow`). Nothing in the repo points that way today.
