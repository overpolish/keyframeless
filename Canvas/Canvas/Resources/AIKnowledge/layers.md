# Layers

Canvas is a layer-based drawing/animation effect. Each clip holds a stack of
**layers** (shapes, imported images, SVGs, and groups). The **Layers panel**
opens to the left of any value/constants editing popover and lists every layer
top-to-bottom (topmost layer draws in front).

A layer is a `KKBezierPath`. The whole stack is serialized to a hidden
`kParamLayerData` param (base64 of `+[KKBezierPath blobFromPaths:]`); the Layers
panel reads and writes that blob directly and rebuilds its rows. (There is no
reactive store / OSC pump in this version - those were removed in the v3
rebuild.)

## Adding layers

- **Drag image files** (png, jpg, jpeg, webp, heic, tiff, gif, bmp) from Finder
  onto the Layers panel to add them as image layers. A drop line shows where the
  new layers will be inserted in the stack. The panel stays open while you
  switch to Finder (an outside-click only dismisses it when it lands in the
  host app).
- (SVG import, shape drawing: pending re-add.)

## Per-layer controls (each row)

- **Visibility** (eye): toggles `hidden`. Hidden layers are dimmed and not
  drawn. **Option-click** the eye to _solo_ a layer (hide all others);
  option-click again to restore. On a group, both apply to the whole subtree.
- **Lock** (padlock): toggles `locked` (the layer is still drawn but not
  interactive on the canvas, and can't be drag-reordered). On a group it locks
  the whole subtree.
- **Name**: click to select. (Double-click to rename: pending re-add.)
- **Thumbnail / icon**: image layers show a thumbnail; groups show a folder;
  shapes show a generic icon.

## Selection

- Click a row to select it. Cmd-click toggles a row in/out of the selection;
  Shift-click extends a range. The selected rows are highlighted; selection
  drives the context-menu actions.
- **Delete / Backspace** removes the selected layers (and a selected group's
  contents). The key is handled by the panel and does not fall through to Final
  Cut.
- **Undo / Redo** (Cmd-Z / Cmd-Shift-Z): layer edits go through Final Cut's
  normal undo, so the standard shortcuts step backward and forward through them
  (add, delete, rename, group/ungroup, reorder, visibility/lock); the panel
  refreshes to match.

## Reordering

- **Drag a row** up or down to restack it; a line shows where it will land
  (topmost layer draws in front). Grab the row anywhere on its body - the name,
  the thumbnail/folder glyph, or empty space. The eye and lock are buttons and
  act on click instead.
- Dragging a row that's part of a multi-selection moves the whole selection.
- **Locked layers can't be dragged** - lock a layer to pin its position in the
  stack (locked rows are skipped when dragging a multi-selection).

## Grouping

Layers can be nested in **groups** (folders). A group is a `KKBezierPath` with
`isGroup = YES` and a `groupID`; its members carry that id in `parentGroupID`
and sit contiguously right after the group in the stack. Nested rows are
indented by their depth.

- **Group** (context menu, or **Cmd-G**): wraps the selected rows in a new
  "Group" folder. Selecting a group includes all its descendants.
- **Ungroup** (on a group row): dissolves the group; its children move up to the
  group's parent level.
- **Remove from Group** (on a nested row): lifts that one row out, placing it
  just above its group.
- Duplicate/Delete on a group act on the whole subtree (children travel with the
  group; duplicated groups get fresh ids).
- **Collapse / expand**: click the disclosure chevron on a group row to hide or
  show its contents (a UI-only state, not saved in the document).
- **Group visibility / lock propagate**: toggling a group's eye or lock applies
  to every layer inside it. Revealing or unlocking a nested layer also reveals /
  unlocks its enclosing groups so it isn't stranded. Option-clicking a group's
  eye solos the whole group.
- **Drag into / out of groups**: drop a row on the lower half of an expanded
  group to make it the group's first child; the drop line indents to show the
  target level. Drop at another row's level (or below everything) to move it
  out. Dragging a group moves its whole subtree, and you can't drop a group
  inside itself.

## Context menu (right-click a row)

- **Rename**: edit the layer name inline (also: double-click the name/thumbnail).
- **Duplicate**: copy the layer(s) (and a group's contents).
- **Delete**: remove the layer(s) (and a group's contents).
- **Group / Ungroup / Remove from Group**: see Grouping above.
- Actions act on the whole selection when you right-click a row that's part of a
  multi-selection; otherwise just that row.

## Rendering

Visible **image layers** are drawn onto the clip, composited front-to-back over
the source frame (the topmost row draws last, on top). Each image fills its
layer's rectangle. Hidden layers, groups, and non-image layers are skipped. The
source clip shows through wherever no layer covers it. The inspector's
mini-viewer preview composites the same layers the same way, so it matches the
main viewer.

## Per-layer transform (Scale + Position)

Each layer animates its own **Scale** and **Position** over the clip, through
the shared Keyframeless timeline (Basic and Advanced timing, easing, motion
blur). The timeline + value popovers edit whichever layer is selected in the
Layers panel; the on-screen controls edit it directly:

- **Position** - a draggable handle plus a curved motion path once it has two or
  more keyposes. Stored normalised (0.5, 0.5 = centred); shown in pixels.
- **Scale** - a transform bounding box (corners + edge handles, a "X% x Y%"
  readout). Percentages, aspect-linked by default, floored at 0%.

Both controls appear in the FCP viewer **and** the inspector mini-viewer (same
handles + keyboard modifiers in each), scoped to the selected layer. Their full
interaction (drag, snap, aspect-lock, fine mode, the motion path) is the shared
behaviour documented in the on-screen-control reference.

### Showing and hiding the controls

The inspector's **On-Screen Controls** toggle and its per-control pills
(Position, Path, Scale) drive visibility. Canvas defaults the global toggle
**on** but the Transform controls **hidden**, so the viewer stays clean;
**Option-hold** reveals hidden controls as dimmed ghosts and **Option-click**
toggles one. A **locked** layer hides its controls.

## Motion blur

The toolbar's motion-blur toggle applies the shared sample-accumulate blur to
the layer animation (and the underlying content), the same engine the other
Keyframeless plugins use.

## Pending re-add (tracked during the v3 rebuild)

- Per-layer **rotation** (lane + on-canvas gizmo).
- Per-layer opacity in the render.
- Shape (stroke / fill) layers and SVG import.
