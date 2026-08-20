# SidekickDock

A native macOS window switcher that looks and feels like Stage Manager — with two deliberate differences:

- **No app groups.** Every window is its own card. Nothing gets bundled or hidden behind a stack.
- **Purely additive activation.** Clicking a card raises and focuses that window. Your other windows stay exactly where they are; nothing is minimised or swept off-screen.

## Features

- Live window previews captured with **ScreenCaptureKit**, refreshed continuously (faster while the dock is revealed, throttled while it is tucked away).
  The strip *peeks* at the screen edge rather than hiding, so it stays on screen: refreshing previews at
  full rate meant CoreAnimation redrawing slivers a few pixels wide that nobody was looking at. Profiling
  with `sample` put idle CPU at ~7%, almost all of it that redraw. Previews now refresh every fourth tick
  while nothing is revealed, and the Accessibility scan that resolves minimised windows is allowed to go
  stale for 8s rather than 2s — safe because anything that takes a window off screen invalidates it
  immediately. Revealing the dock forces a fresh scan and capture. Idle CPU is now ~0.5%.
- **One dock per display.** Windows are grouped by the screen that actually holds them, and each display gets its own strip.
- **Edge reveal.** The strip tucks against the screen edge showing a slim sliver; rest the pointer at the edge and it springs open. Clicking a sliver activates that window directly, without waiting for the reveal.
- **Stays out of the way.** When the active window fills the screen — maximised or natively full-screen — the resting sliver disappears, but the edge trigger keeps working so the dock is still one hover away. Displays with no windows hide their panel entirely.
- **3D perspective.** Cards share a single vanishing point, calibrated against a screenshot of the real Stage Manager.
- **Native chrome.** Vibrancy material, continuous-corner cards, app-icon badges, spring animations, hover and press feedback, accent-coloured ring on the active window.
- Minimised windows stay in the strip, dimmed and badged, keeping their last preview and their place in the order; one click restores them. Closed windows drop out.
- **Traffic lights on every card** when the strip is open: close, minimise, and full screen. Resting on the green button opens a **Move & Resize** menu — halves and quarters, plus Fill & Arrange layouts that tile the card's window together with its neighbours on that display.
- **⌘Tab replacement.** The dock takes over the system application switcher and cycles *windows* instead of app groups, reusing the previews it already holds. ⌘⇧Tab reverses, arrows move, Escape cancels, hover selects, click picks. The overlay always appears on the primary display, grouped by display — external screens first, primary last — in the same order as the strips. It only draws after 150ms, so a quick ⌘Tab-and-release switches without a flash. Turn it off in Settings to get the system switcher back.
- Right-click a card for *Bring to Front*, *Minimise*, *Close Window*, and *Quit App*.
- Menu-bar item with *Reveal Dock* and *Settings*.
- Settings: screen edge (left/right), preview size, reveal delay, window titles, minimised-window inclusion, ⌘Tab replacement, launch at login.
- **Launch at login** via `SMAppService.mainApp`. The toggle reads its state back from the
  system on every appearance rather than caching it, so disabling the login item in System
  Settings is reflected here. Note the registration records the bundle's *current* path —
  move the app and you must re-toggle it.

### A note on private API

Focus-without-activation is not expressible through any public framework. `SkyLight.swift`
resolves `SLPSSetFrontProcessWithOptions` and `SLPSPostEventRecordTo` dynamically at run
time, so a future macOS that removes them degrades to `NSRunningApplication.activate`
rather than crashing.

Two other pieces reach outside the public frameworks. `SpaceInspector.swift` asks
`SLSCopyManagedDisplaySpaces` which displays are showing a full-screen Space, because the
CoreGraphics window list only describes the current Space and so cannot see a full-screen
window at all. And the ⌘Tab replacement needs a `CGEventTap`: ⌘Tab is a reserved system
shortcut, so it never reaches an ordinary key monitor and cannot be claimed with
`RegisterEventHotKey`. Both fail soft — no Spaces information, or no tap and the system
switcher simply keeps working.

Three ordering rules in `SkyLight.swift` are load-bearing, all established by measurement:

1. The key-window events are sent **before** the process switch. An app raises whichever
   window it believes is focused at the moment it is activated, so telling it afterwards is
   too late — it will already have raised a stale window on another display.
2. They are sent **again after** the switch, when one happened. The window server discards
   those events for a process that is not frontmost, and the switch itself fronts the app
   without reordering its windows — so the clicked window stayed behind another app's, and
   only a second click appeared to work. `AXRaise` used to mask this.
3. The process switch happens **only if the app is not already frontmost**. Fronting an
   already-front app re-runs its activation path, with the same consequence. The key-window
   events alone are enough to raise and focus a window inside the active app.

Switching between two windows of one app also names the window losing focus, so the window
server can handle the change without involving the app.

Even with all of that right, the window server sometimes accepts the focus request, reports
success, and does not raise the window — the click looks like it did nothing. It is not a
timing problem: a window that has not come forward 120ms later is still buried a second
later. So `WindowActivator` checks the outcome instead of trusting the return code, and
falls back to `AXRaise` on the rare occasions the check fails. That is the one place the
`AXRaise` side effect is worth accepting, because the alternative is a dropped click.

`NSRunningApplication.unhide()` is called only when the app is genuinely hidden. It orders
every window of an app forward, on every display, so calling it unconditionally — as a
convenience before raising — was for a long time the real cause of "clicking a card on one
display raises another window on the other".

Minimising an app's front window makes macOS promote that app's *next* window to key, which
is frequently on another display — so a sibling appears to leap onto the other screen. The
dock pre-empts this for its own minimise button by handing focus to the display's next
window first, so the app is no longer frontmost when it loses the window. A minimise made
with the window's own button or ⌘M is left alone, keeping the system's behaviour.

Correcting that external case was tried and removed. It cannot be intercepted, only undone
afterwards, and `SLSOrderWindow` — the way to reorder without involving the app — does not
work here: the window server rejects it for a window this process does not own, both through
the main connection (error 1000) and through the owning connection from `SLSGetWindowOwner`
(a mach error). What remained was raising the previous front back through Accessibility,
driven by an `AXObserver` on `kAXWindowMiniaturizedNotification`, which corrected in ~250ms
but still showed one frame of the promoted sibling.

## Troubleshooting

Set `defaults write com.sidekickdock.app debugLogging -bool YES` to log window enumeration,
clicks, and Accessibility resolution to `~/Library/Logs/SidekickDock.log`. It is off by
default so there is no file I/O on the click path.

## Requirements

- macOS 14 or later
- Swift 5.9+ toolchain (Xcode or Command Line Tools)

## Build and run

```bash
./Scripts/create-signing-identity.sh   # once, so permissions survive rebuilds
./Scripts/build.sh release
open build/SidekickDock.app
```

`create-signing-identity.sh` generates a self-signed code-signing certificate in your login
keychain. Without it the app is ad-hoc signed, and because an ad-hoc signature changes on
every build macOS treats each rebuild as a different app and re-asks for Screen Recording
and Accessibility. With the identity the designated requirement becomes
`identifier "com.sidekickdock.app" and certificate root = …`, which is stable, so your
grants persist.

`build.sh` compiles with SwiftPM, assembles a proper `.app` bundle from `Resources/Info.plist`, and signs it with that identity when it is available.

## Publishing

```bash
./Scripts/release.sh --dry-run    # everything except submitting to Apple
./Scripts/release.sh 1.1          # set the version, notarise, and package a disk image
```

Distribution is **Developer ID with notarisation**, not the Mac App Store. The app resolves
private SkyLight symbols and drives other applications through the Accessibility API, and
neither survives the sandbox the store requires. Notarisation itself is an automated malware
scan rather than a review, so the private symbols are not an obstacle there.

`release.sh` finds your *Developer ID Application* certificate, builds with the hardened
runtime and a secure timestamp — both preconditions for notarisation — then notarises and
staples the app, packages it into a signed disk image, and notarises that too. The app gets
its own ticket rather than only the image, so a first launch on a machine that cannot reach
Apple still works. No entitlements file is needed: the app is not sandboxed, and both
permissions it uses are granted by the user at run time.

Credentials are stored once, using an app-specific password from appleid.apple.com:

```bash
xcrun notarytool store-credentials sidekickdock-notary \
  --apple-id you@example.com --team-id <TEAM_ID> --password xxxx-xxxx-xxxx-xxxx
```

One consequence of releasing: macOS keys Screen Recording and Accessibility grants to the
signature, so the first Developer ID build is a different app as far as it is concerned and
will ask for both again — on your own Mac as well. Every release after that keeps its grants,
because the Developer ID identity does not change.

## Permissions

SidekickDock asks for two grants on first launch (System Settings → Privacy & Security):

| Permission | Why |
| --- | --- |
| **Screen Recording** | Renders the live window previews. |
| **Accessibility** | Raises and focuses the window you click, without touching the others. |

After granting Screen Recording for the first time, quit and relaunch the app so macOS hands over the new capture privileges.

## How it works

| Layer | Responsibility |
| --- | --- |
| `WindowEnumerator` | Builds the window list from the CoreGraphics *on-screen* list, then adds back windows the Accessibility API confirms are minimised. The full `.optionAll` list is unusable alone: it also returns other-Space windows and hundreds of stale helper surfaces whose bogus frames land on the wrong display. |
| `MinimizedScanner` | The only reliable way to tell "minimised" from "on another Space" — CoreGraphics reports both as simply absent. Reads `kAXMinimizedAttribute`, cached briefly and re-scanned the instant a window leaves the screen. |
| `ThumbnailEngine` | An actor that captures downscaled per-window images via `SCScreenshotManager`, serialising work and caching the shareable-content query. |
| `WindowStore` | Main-actor source of truth: window list, previews, stable slot ordering that never reshuffles on click, per-display assignment, screen-filling detection, adaptive refresh cadence. Bridges the minimise/restore animations so cards never blink out mid-transition. |
| `WindowActivator` | Un-minimises the window and hands focus to `SkyLight`, which is what brings it forward. Notably it does *not* call `AXRaise`: that asks the app to raise the window, and apps run their own window ordering in response. Resolves the `AXUIElement` by window ID, falling back to exact title and near-exact position — and to nothing at all rather than guessing, since a guess means raising a window the user did not click. |
| `SkyLight` | Gives the clicked window keyboard focus *without* activating its app. Activating an app raises its frontmost window on **every** display it occupies, so a click on one display would disturb the others. This is the one piece that needs private API; if the symbols cannot be resolved it falls back to ordinary app activation. |
| `DockController` / `DockManager` | One borderless non-activating `NSPanel` per display, plus pointer monitoring and reveal/hide choreography. The panel is always hit-testable and its *frame* shrinks to the sliver when collapsed; toggling `ignoresMouseEvents` from pointer events instead would race the click and drop it through to the desktop. |
| `DockStripView` | SwiftUI presentation of the strip and its cards. |
