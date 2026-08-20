# SidekickDock internals

Notes on how the dock is built and, more usefully, on the things that turned out not to work.
Almost every rule here was established by measurement rather than reasoning, and several of
them overturned a plausible-sounding explanation.

## Architecture

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

`build.sh` compiles with SwiftPM, assembles a proper `.app` bundle from `Resources/Info.plist`,
and signs it. `SIGN_IDENTITY` and `SIGN_TIMESTAMP` override the defaults — that is how
`release.sh` reuses the same bundle assembly with a Developer ID certificate.

Launch at login goes through `SMAppService.mainApp`. The toggle reads its state back from the
system on every appearance rather than caching it, so disabling the login item in System
Settings is reflected in the app. The registration records the bundle's *current* path.

## Private API

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

## The three ordering rules

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

## Dropped switches

Even with all of that right, the window server sometimes accepts the focus request, reports
success, and does not raise the window — the click looks like it did nothing. A failed call
is byte-for-byte identical to a successful one: `setFront rc=0`, `makeKey rc=0`, correct
ordering, window still buried.

It is not a timing problem. Probing at 120ms, 300ms, 600ms and 1s showed that a window which
has not come forward at 120ms is still buried a second later, so waiting longer would never
have helped. Retrying the same window-server call does not help either — it corrected 0 of 5
failures. It is also app-specific: some apps switched perfectly every time while another
stuck, which is why testing the wrong pair of apps first produced a false "it all works".

So `WindowActivator` checks the outcome instead of trusting the return code, and falls back
to `AXRaise` on the rare occasions the check fails. Measured 16/16 successful switches with
the correction against 8/16 without. That is the one place the `AXRaise` side effect is worth
accepting, because the alternative is a dropped click.

`isBuried()` deliberately ignores the target app's own windows — a sheet or palette above its
parent is legitimate, and treating it as failure would re-raise the parent out from under its
own dialog. A generation counter drops any correction whose window the user has since clicked
away from, so a retry cannot fight a newer click.

## Windows that leap between displays

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

## Idle cost

The strip *peeks* at the screen edge rather than hiding, so it stays on screen: refreshing
previews at full rate meant CoreAnimation redrawing slivers a few pixels wide that nobody was
looking at. Profiling with `sample` put idle CPU at ~7%, almost all of it that redraw.

Previews now refresh every fourth tick while nothing is revealed, and the Accessibility scan
that resolves minimised windows is allowed to go stale for 8s rather than 2s — safe because
anything that takes a window off screen invalidates it immediately. Revealing the dock forces
a fresh scan and capture. Idle CPU is now ~0.5%.

Note when profiling that `ps %CPU` is a lifetime average while `top` is instantaneous;
comparing the two produces phantom regressions.

## Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The `DEVELOPER_DIR` prefix is needed because XCTest ships with Xcode, not with the Command
Line Tools; without it the toolchain reports *no such module 'XCTest'*. It is only needed for
the tests — building and releasing the app works with the Command Line Tools alone.

The suite covers the arithmetic that has regressed most often and is hardest to see going
wrong: the tiling geometry (`WindowTiler.frame(for:in:)`), the AppKit ↔ CoreGraphics flip and
display ownership (`ScreenGeometry`), the switcher's wrap-around and most-recently-used
traversal (`SwitcherIndex`), and recency ordering (`UsageHistory`).

Each of those was reachable only through a real screen arrangement, so the pure arithmetic was
lifted out into functions that take their world as arguments. That refactor immediately found a
bug: a zero-area window sitting *inside* the external display was assigned to the primary,
because the off-screen fallback compared distances to display **centres**. It now measures
distance to the display's edges, which is zero for a display that contains the point.

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

## Troubleshooting

Set `defaults write com.sidekickdock.app debugLogging -bool YES` to log window enumeration,
clicks, and Accessibility resolution to `~/Library/Logs/SidekickDock.log`. It is off by
default so there is no file I/O on the click path.

**SidekickDock missing from the Screen Recording list.** macOS does not reliably add an app to
*Screen & System Audio Recording* when it asks: observed on macOS 26 with a Developer ID build
that was registered with LaunchServices, `CGRequestScreenCaptureAccess()` returned false,
showed no prompt, and added no row — so *Grant…* opened a list the app was not in. A control
app calling ScreenCaptureKit instead failed identically (`-3801`, no prompt, no row), so
swapping APIs does not help. Click **+** below the list and choose SidekickDock; the
Permissions tab offers *Reveal App in Finder* and *Copy Path* to aim the file picker at the
running bundle.
