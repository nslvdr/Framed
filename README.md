# Framed

A polished screenshot app for macOS 15+. It lives in the menu bar and every capture opens straight into an annotation editor.

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
