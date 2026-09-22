# Column-view inspector slide — build spec

## Goal in one sentence
When the inspector panel opens in **column view**, the column stack should slide left as one rigid unit and disappear **underneath** a fixed sidebar, and slide back out on close — while the sidebar itself never moves.

This document is a self-contained handoff. Read it top to bottom before writing code.

---

## 1. App context

- **Project:** `~/Data/Code/transfer` — a macOS 27 SwiftUI + AppKit SFTP file browser (Swift package). Read `HANDOFF.md` first.
- **Window chrome is AppKit**, not SwiftUI's `NavigationSplitView`. It is an `NSSplitViewController` (`ChromeController`) hosting three SwiftUI columns:
  - **Sidebar** (`SidebarColumn`): servers + starred + live files.
  - **Detail / content** (`DetailColumn`): the file browser, one of three view modes — icon grid, list (`NSTableView`), or **column browser** (`NSBrowser`).
  - **Inspector** (`InspectorColumn`): file info + preview. Toggled with ⌘⇧I.
- **Key files:**
  - `Sources/TransferUI/WindowChrome.swift` — `ChromeController.install(...)` builds the three `NSSplitViewItem`s. This is where sidebar/inspector sizing and collapse behavior live.
  - `Sources/TransferUI/ColumnBrowser.swift` — the column view. `ColumnBrowser` is an `NSViewRepresentable` wrapping `TiledBrowser: NSBrowser`. Columns are a fixed width (`TiledBrowser.columnWidth = 260`). The delegate `Coordinator` loads columns from `TransferModel`.
  - `Sources/TransferUI/ContentView.swift` — `InspectorColumn`, `iconView`, and the SwiftUI wiring.
  - `Sources/TransferModel.swift` — `columnRoot`, `snapshot.path`, `columnItems(_:)`; the column depth = number of path components from `columnRoot` to the selected leaf, plus one.

## 2. Build / run loop

```
Scripts/package-app.sh      # builds AND repackages the .app bundle. `swift build` alone does NOT repackage — you will test a stale app if you use it.
open .build/Transfer.app
```

To verify visually you must drive the real app (there is a live SFTP server configured as “live”). Capture frames with `screencapture -x -o`. Still frames hide sub-frame jitter; when in doubt, watch it live.

---

## 3. Exact desired behavior (column view only)

Let **C** = total width of all loaded columns (`columnCount * 260`). Let **P** = width of the content pane (shrinks as the inspector opens).

1. **Sidebar is immovable.** Its left edge, right edge, and width never change during the inspector animation. Not by one pixel. (This is the property the user cares about most and kept catching us violating.)
2. **Inspector opens from the right** and animates its width from 0 to its full width (~240–270 pt) over the standard duration.
3. **While C ≤ P** (columns fit with room to spare): the columns do **not** move at all. The inspector simply consumes the empty space to the right of the last column. No column shift.
4. **Once the inspector’s left edge would cover the last (deepest) column** — i.e. as P shrinks below C — the whole column stack **translates left as one rigid piece**, in lockstep with the inspector animation, so the deepest column’s right edge stays flush against the inspector’s left edge (they “abut”).
5. **The leftmost column slides left past the content pane’s left edge and disappears UNDER the sidebar** — the sidebar is drawn on top; columns vanish behind it, they are not clipped at a visible line to the right of the sidebar, and they never draw over the sidebar.
6. **On close, everything reverses smoothly** — the stack slides right, columns reappear from under the sidebar, and settle back to their resting positions.
7. Motion is one continuous translation, not a resize of individual columns and not a late “snap”. Column widths stay fixed at 260 the whole time.

The same must hold in reverse and must feel identical whether you open with ⌘⇧I or the toolbar/menu.

## 4. What must NOT regress

- **Icon view**: inspector opening pushes the grid narrower; the grid reflows (fewer columns) but items are left-packed at fixed width and must not shimmy. Already correct — do not change `iconView` unless necessary.
- **List view**: the Name column gives up width, the other columns stay; a horizontal scroller appears only if the window is too narrow. Already correct.
- **Toolbar** (transparent titlebar, back/forward, view switcher, search) must keep working; content sits below the toolbar via `BelowToolbarController`.
- **Sidebar collapse/expand** (⌘⇧S) animation must stay smooth.
- **Drag-to-desktop** from all three views (there is a subtle NSBrowser drag bug already fixed in `ColumnBrowser.swift` `validateDrop`; do not reintroduce it).
- **Column drag, Quick Look (spacebar), and the `..` parent row** in column view must keep working.

## 5. What has already been tried, and why it failed (do not repeat)

1. **Re-tiling columns to fit the pane** (changing each column’s width during the animation): every column visibly resized — read as an “overlay/resize”, not a slide. Rejected.
2. **A wrapping container that offsets the NSBrowser’s frame left and clips it** (`SlidingColumnContainer`): `NSBrowser` insists on managing its **own** horizontal scroll, and `browser.lastColumn` reported 0 in some states, so the offset math misfired. The browser scrolled itself independently, chopping the leftmost column at the content-pane edge and, in narrow windows, drawing over the sidebar. Fragile — worked in one window size, broke in others. Reverted.
3. **Native NSBrowser push** (let the pane shrink, browser scrolls internally): keeps the sidebar fixed but the leftmost column clips at the content-pane’s left edge (a visible line just right of the sidebar), NOT under the sidebar. User rejected: “just shoved the columns to the left.”

## 6. Root cause already fixed (keep this)

The sidebar used to shrink a few pixels when the inspector opened. Cause: the split view distributed the inspector’s width across **both** siblings, and the content pane hit its old 420 pt minimum and pushed into the sidebar. Fixed in `WindowChrome.swift`:
- `sidebarItem.holdingPriority = 260`, `inspectorItem.holdingPriority = 260`, `detailItem.holdingPriority = 250` (content pane yields first).
- `detailItem.minimumThickness = 260` (was 420) so the content pane can absorb the whole inspector without pushing into the sidebar.
- `inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView`.
- Note: the window itself **cannot grow** to make room, because `ChromeContainer` pins the split view to the SwiftUI-assigned window size with explicit width/height constraints. Keep that in mind — you cannot rely on the window growing.

**Verified:** the sidebar divider now stays at the same x with the inspector closed vs open. Preserve this.

## 7. Recommended approach

For columns to slide **under** the sidebar (requirement #5), the content pane must extend the **full width of the window** with the **sidebar floating on top of it**. Side-by-side split items cannot do this — a column can never render in the sidebar’s region.

macOS 26+ provides the native mechanism: **`NSSplitViewItem.automaticallyAdjustsSafeAreaInsets`** (see `NSSplitViewItem.h`). When set `true` on the **content/detail** item, sidebars and inspectors are drawn **overlaid on top** of it, and its `safeAreaInsets` grow to mark the covered regions. The content (the `NSBrowser`) then lays out full-width beneath the overlays.

Suggested plan:
1. In `WindowChrome.swift`, set the detail item’s `automaticallyAdjustsSafeAreaInsets = true` so sidebar + inspector overlay the full-width content. Re-check the `detail.safeAreaRegions = []` line — it currently disables safe-area response for the toolbar inset and will conflict; you will need the browser to respect the leading (sidebar) and trailing (inspector) safe-area insets while still starting content below the toolbar.
2. Make the column browser honor those safe-area insets: its visible region is the safe area; the deepest column pins to the trailing safe-area edge (inspector’s left edge), and columns overflow **past the leading safe-area edge under the sidebar**, where the overlaid sidebar hides them.
3. Because `NSBrowser`’s internal horizontal scrolling is unreliable for this, strongly consider **replacing `NSBrowser` with a custom column view**: a horizontal stack of fixed-width `NSTableView` columns inside a single scroll/clip view whose content offset you control and animate directly. This gives pixel-exact, synchronized translation and removes every `NSBrowser` quirk (the drag bug, `lastColumn`, forced scrolling). It is more code but it is the only fully reliable path to requirement #5. Keep the existing delegate logic (column loading from `TransferModel`, the `..` parent row, drag/drop, Quick Look, double-click-to-open) — port it, don’t rewrite the model.
4. Whatever you build, **the animation must be driven so the column translation is interpolated frame-by-frame in lockstep with the inspector’s width animation** (same duration and timing curve), not applied at the end.

## 8. Acceptance test (do all of these, live)

1. Narrow window, navigate 3–4 columns deep so C > P. Open inspector: the stack slides left as one piece, deepest column abuts the inspector, leftmost disappears under the sidebar, sidebar does not move. Close: reverses smoothly.
2. Wide window, 2 columns (C < P). Open inspector: columns do not move at all; inspector fills empty space; sidebar does not move.
3. Toggle rapidly several times — no flicker, no drift, sidebar never moves.
4. Switch to icon and list views — their behavior is unchanged and smooth.
5. Drag a file from a column to the Finder desktop — still works. Spacebar Quick Look — still works. `..` parent row — still works.
6. Collapse/expand the sidebar (⌘⇧S) — still smooth.

## 9. Current git state

- Last commit: `d10e8ac`. Everything since is uncommitted (drag fix, previews, Quick Look, icon/list inspector, icon label wrapping, the sidebar holding-priority fix). Do not commit until the user asks. No AI-attribution lines in commits unless the user says otherwise.
