# Framed

A polished screenshot app for macOS 15+. It lives in the menu bar and every capture opens straight into an annotation editor.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/nslvdr/Framed/main/scripts/install.sh | bash
```

This installs the latest release into `/Applications` (or `~/Applications`) and launches it. Run it again to update. Framed isn't notarized, so a browser-downloaded copy would be blocked by Gatekeeper; the script sidesteps that.

## Release

```sh
scripts/make-signing-cert.sh   # once per machine: creates the self-signed "Framed Release" identity
scripts/release.sh 0.2.0       # universal build → tag v0.2.0 → GitHub release with Framed.zip
```

Releases are signed with that self-signed identity: it carries no personal details and keeps users' Screen Recording permission across updates. Always use the same certificate (restore it from the `.p12` backup on a new machine); a new one makes every user re-grant the permission once.

## Build & run

```sh
scripts/bundle.sh --run   # builds build/Framed.app and launches it
scripts/test.sh           # runs the test suite
```

On first capture, grant **Screen & System Audio Recording** permission in System Settings. The bundle script signs with your Apple Development identity when available so the permission survives rebuilds.

## Shortcuts

| Global | |
|---|---|
| ⇧⌘4 | Capture area: drag a region (Space toggles window mode, Esc cancels) |
| ⇧⌘3 | Capture the screen under the cursor |

These replace the macOS screenshot shortcuts. On launch, Framed offers to turn the system ones off if they are still enabled (they can be re-enabled in System Settings → Keyboard → Keyboard Shortcuts… → Screenshots).

The menu bar panel has a Capture button (click or Return to repeat your last method — Area, Window or Screen; the chevron offers all three), your three most recent captures, copied or saved (click to reopen in the editor, drag into any app, right-click for more), and Launch at Login. The icon flashes a checkmark after a copy or save.

| Editor | |
|---|---|
| ⌘C / ⌃C / Return | Copy to clipboard and close |
| ⌘S | Save PNG to `~/Pictures/Framed` and close |
| Esc | Step back: cancel drag → close popover → deselect → leave crop → close (asks first if you annotated) |
| V | Select: drag to move, handles to resize, Delete to remove, double-click text to edit |
| ⌘Z / ⇧⌘Z | Undo / redo |
| A R T P H B N C | Arrow, rectangle, text (click existing text to edit), pen, highlighter, pixelate, numbered step, crop |

## Roadmap

- Phase 2: screen recording / GIF
- Phase 3: scrolling capture
