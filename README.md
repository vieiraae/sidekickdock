# SidekickDock

**Stage Manager, without the parts that get in your way.**

A native macOS window switcher that tucks a strip of live window previews against the edge of
every display. Rest your pointer at the edge and it springs open; click a card and that window
comes forward.

https://github.com/user-attachments/assets/616cbe62-da24-4b7b-ad6a-c10285eee9cf

Two deliberate differences from the built-in Stage Manager:

- **No app groups.** Every window is its own card. Nothing is bundled or hidden behind a stack.
- **Purely additive.** Clicking a card raises and focuses *that* window. Everything else stays
  exactly where it is — nothing is minimised or swept off-screen.

## Highlights

- **Live previews** of every window, captured with ScreenCaptureKit and refreshed continuously.
- **One strip per display**, showing only the windows actually on that screen.
- **Edge reveal.** The strip rests as a slim sliver and opens on hover. Clicking a sliver
  activates that window straight away, no waiting.
- **Traffic lights on every card** — close, minimise, full screen — plus a **Move & Resize**
  menu with halves, quarters, and Fill & Arrange tiling.
- **⌘Tab replacement** that cycles *windows* rather than app groups, reusing previews it
  already holds. Optional; switch it off to get the system switcher back.
- **Minimised windows stay put**, dimmed and badged, holding their place in the order. One
  click restores them.
- **Stays out of the way.** The sliver disappears when the active window fills the screen, and
  displays with no windows hide their strip entirely.
- **Native throughout** — vibrancy, continuous-corner cards, spring animations, a shared 3D
  vanishing point calibrated against the real Stage Manager, and a menu-bar item.
- **Light on idle**, around 0.5% CPU.

Settings cover the screen edge, preview size, reveal delay, window titles, minimised windows,
the ⌘Tab replacement, and launch at login.

## Install

**Requires macOS 14 or later.**

### From the disk image

Download the latest `SidekickDock-x.y.z.dmg` from
[Releases](https://github.com/vieiraae/sidekickdock/releases), open it, and drag SidekickDock
to Applications. It is signed with a Developer ID certificate and notarised by Apple, so it
opens without a Gatekeeper warning.

### From source

Needs a Swift 5.9+ toolchain (Xcode or the Command Line Tools).

```bash
git clone https://github.com/vieiraae/sidekickdock.git
cd sidekickdock
./Scripts/create-signing-identity.sh   # once, so permissions survive rebuilds
./Scripts/build.sh release
open build/SidekickDock.app
```

`create-signing-identity.sh` generates a self-signed certificate in your login keychain.
Without it the app is ad-hoc signed, and because an ad-hoc signature changes on every build,
macOS treats each rebuild as a different app and re-asks for permissions.

## First launch

SidekickDock needs two grants in System Settings → Privacy & Security:

| Permission | Why |
| --- | --- |
| **Screen Recording** | Renders the live window previews. |
| **Accessibility** | Raises the window you click, without touching the others. |

The Permissions tab in Settings walks you through both. **After granting Screen Recording,
quit and relaunch the app** so macOS hands over the new capture privileges.

If SidekickDock does not appear in the Screen Recording list, click **+** below the list and
choose it — macOS does not always add an app on request. Settings offers *Reveal App in
Finder* and *Copy Path* to make that quick. See
[Troubleshooting](docs/internals.md#troubleshooting) for the details.

One gotcha: *Launch at login* records the bundle's **current path**, so if you move the app
afterwards you need to toggle it off and on again.

## Under the hood

Focus-without-activation is not expressible through any public framework, so the dock resolves
a handful of private SkyLight symbols at run time and degrades gracefully if they ever
disappear.

That, the measurements behind it, and the approaches that were tried and abandoned are written
up in **[docs/internals.md](docs/internals.md)** — along with the architecture, the publishing
pipeline, and troubleshooting.

## License

[MIT](LICENSE) © Alexandre Vieira
