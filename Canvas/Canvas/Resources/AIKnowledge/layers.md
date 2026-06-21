# Layers

Canvas is a layer-based drawing/animation effect. Each clip holds a stack of **layers** (shapes, imported images, SVGs, and groups). The **Layers panel** opens to the left of any value/constants editing popover and lists every layer top-to-bottom (topmost layer draws in front).

A layer is a `KKBezierPath`. The whole stack is serialized to a hidden `kParamLayerData` param (base64 of `+[KKBezierPath blobFromPaths:]`); the Layers panel reads and writes that blob directly and rebuilds its rows. (There is no reactive store / OSC pump in this version - those were removed in the v3 rebuild.)

## Adding layers

- **Drag image files** (png, jpg, jpeg, webp, heic, tiff, gif, bmp) from Finder onto the Layers panel to add them as image layers. A drop line shows where the new layers will be inserted in the stack. The panel stays open while you switch to Finder (an outside-click only dismisses it when it lands in the host app).
- (SVG import, shape drawing: pending re-add.)

## Per-layer controls (each row)

- **Visibility** (eye): toggles `hidden`. Hidden layers are dimmed and not drawn. **Option-click** the eye to _solo_ a layer (hide all others); option-click again to restore. On a group, both apply to the whole subtree.
- **Lock** (padlock): toggles `locked` (the layer is still drawn but not interactive on the canvas, and can't be drag-reordered). On a group it locks the whole subtree.
- **Name**: click to select. (Double-click to rename: pending re-add.)
- **Thumbnail / icon**: image layers show a thumbnail; groups show a folder; shapes show a generic icon.

## Selection

- Click a row to select it. Cmd-click toggles a row in/out of the selection; Shift-click extends a range. The selected rows are highlighted; selection drives the context-menu actions.
- **Delete / Backspace** removes the selected layers (and a selected group's contents). The key is handled by the panel and does not fall through to Final Cut.
- **Undo / Redo** (Cmd-Z / Cmd-Shift-Z): layer edits go through Final Cut's normal undo, so the standard shortcuts step backward and forward through them (add, delete, rename, group/ungroup, reorder, visibility/lock); the panel refreshes to match. Changing the selected layer is itself undoable.

### Auto-select layers

The **Auto-select layers** checkbox at the top of the Layers panel (off by default) lets you pick a layer by clicking it directly in the **viewer** instead of hunting for its row. It also works in the editing popover's mini preview. The pointer changes to a hand over a selectable layer.

- It is **alpha-aware** for images: clicking a transparent part of a layer falls through and selects whatever opaque layer is beneath, so you select what you actually see.
- For **drawn paths** it picks the layer whose **stroke** you click on (or near); clicking inside an open path's hollow interior falls through to whatever is behind it, since there's nothing there to hit. Images and paths share one front-to-back order, so you always get the topmost thing under the pointer.
- It respects the layer's transform, so a moved / scaled / rotated layer is picked where it actually appears.
- Locked and hidden layers are skipped.
- In the **main viewer** a layer is pickable only if there's something to edit at the current playhead: it has at least one constant (non-animated) value, or one of its animated lanes has a keypose at the playhead (including the held lead-in / lead-out before the first / after the last keypose). A fully-animated layer parked between its keyposes isn't pickable - and the hand cursor only appears over a layer you can actually select.
- In the editing popover's **mini preview** the gating instead matches the layer rows for that popover - e.g. a keypose popover only lets you pick layers that have a keypose at that time.

## Reordering

- **Drag a row** up or down to restack it; a line shows where it will land (topmost layer draws in front). Grab the row anywhere on its body - the name, the thumbnail/folder glyph, or empty space. The eye and lock are buttons and act on click instead.
- Dragging a row that's part of a multi-selection moves the whole selection.
- **Locked layers can't be dragged** - lock a layer to pin its position in the stack (locked rows are skipped when dragging a multi-selection).

## Grouping

Layers can be nested in **groups** (folders). A group is a `KKBezierPath` with `isGroup = YES` and a `groupID`; its members carry that id in `parentGroupID` and sit contiguously right after the group in the stack. Nested rows are indented by their depth.

- **Group** (context menu, or **Cmd-G**): wraps the selected rows in a new "Group" folder. Selecting a group includes all its descendants.
- **Ungroup** (on a group row): dissolves the group; its children move up to the group's parent level.
- **Remove from Group** (on a nested row): lifts that one row out, placing it just above its group.
- Duplicate/Delete on a group act on the whole subtree (children travel with the group; duplicated groups get fresh ids).
- **Collapse / expand**: click the disclosure chevron on a group row to hide or show its contents (a UI-only state, not saved in the document).
- **Group visibility / lock propagate**: toggling a group's eye or lock applies to every layer inside it. Revealing or unlocking a nested layer also reveals / unlocks its enclosing groups so it isn't stranded. Option-clicking a group's eye solos the whole group.
- **Drag into / out of groups**: drop a row on the lower half of an expanded group to make it the group's first child; the drop line indents to show the target level. Drop at another row's level (or below everything) to move it out. Dragging a group moves its whole subtree, and you can't drop a group inside itself.
- **Group transform**: a group is a layer like any other - it has its own Scale, Position, Rotation (all three axes: X/Y tilt + Z spin), and Opacity (animatable on the timeline, editable with the same on-screen controls). A group's transform applies on top of each member's own transform as a rigid 3D composition, so moving / scaling / rotating / tilting / fading a group does the same to everything inside it as a unit - each member keeps its own rotation and the whole group rotates around the group's pivot. That pivot is the group's own **Anchor** point, set to the centre of the group's contents when the group is created and stored there - so moving a member around inside the group doesn't drift the pivot or shift the other members. Drag the group's anchor square (or keypose its Anchor lane) to move the pivot, just like a single layer; nested groups compose (a child group's transform stacks under its parent's). Selecting a group on the canvas shows its Position handle, scale box, rotation rings, and anchor square just like a single layer.

## Context menu (right-click a row)

- **Rename**: edit the layer name inline (also: double-click the name/thumbnail).
- **Duplicate**: copy the layer(s) (and a group's contents).
- **Delete**: remove the layer(s) (and a group's contents).
- **Group / Ungroup / Remove from Group**: see Grouping above.
- Actions act on the whole selection when you right-click a row that's part of a multi-selection; otherwise just that row.

## Rendering

Visible **image layers** are drawn onto the clip over the source frame. Each image fills its layer's rectangle, transformed by its own Scale / Position / Rotation / Anchor / Opacity composed with any enclosing group's transform. Hidden layers and non-image layers are skipped, and a group draws nothing itself (it only transforms its members). The source clip shows through wherever no layer covers it. The inspector's mini-viewer preview composites the same layers the same way, so it matches the main viewer.

**Stacking order**: layers are drawn back-to-front by their **3D depth** (centre distance from the camera), with **layer-list order** as the tiebreak. In practice:

- With no 3D tilt, every layer's centre is at the same depth, so **layer order decides stacking** - the topmost row draws on top, exactly like normal 2D compositing.
- When a **group is tilted** in 3D so a lower layer's centre swings physically in front, that layer draws on top regardless of its list position (and flips back as you rotate past edge-on). In-plane (Z) spin doesn't change depth, so layer order still governs there.

So layer order rules in 2D and is the fallback everywhere; real 3D depth only overrides it when a tilt actually puts one layer in front of another. (Stacking is decided per layer by its centre, not per pixel, which is exact for the non-overlapping image planes Canvas composites.)

## Per-layer transform (Scale + Position)

Each layer animates its own **Scale** and **Position** over the clip, through the shared Keyframeless timeline (Basic and Advanced timing, easing, motion blur). The timeline + value popovers edit whichever layer is selected in the Layers panel; the on-screen controls edit it directly:

- **Position** - a draggable handle plus a curved motion path once it has two or more keyposes. Stored normalised (0.5, 0.5 = centred); shown in pixels.
- **Scale** - a transform bounding box (corners + edge handles, a "X% x Y%" readout). Percentages, aspect-linked by default, floored at 0%.
- **Anchor** - a small square at the pivot that Rotation and Scale swing around. Stored normalised (0.5, 0.5 = the layer centre); shown in pixels.

Both controls appear in the FCP viewer **and** the inspector mini-viewer (same handles + keyboard modifiers in each), scoped to the selected layer. Their full interaction (drag, snap, aspect-lock, fine mode, the motion path) is the shared behaviour documented in the on-screen-control reference.

### Anchor point

The **Anchor** is the pivot Rotation and Scale swing around. It sits at the layer centre by default, so rotation spins around the middle and scale grows from it. Move it onto a corner and the layer rotates around that corner and scales out from it; on an edge midpoint and it hinges along that edge; off the layer entirely and it orbits a point in empty space. On its own the anchor does nothing visible - it only matters when there is rotation or scale to pivot.

It is an animatable lane like the others (leave it constant for a fixed pivot, or keypose it to move the pivot over time), and it works the same on a **group**, where it shifts the group's pivot off its content centre.

Set it three ways: drag the square on the viewer, drag it on the inspector mini-viewer, or type X / Y in the keypose value popover (off-layer values are allowed). Hold **Cmd** while dragging to snap the pivot to the layer's centre / corners / edge-midpoints / thirds, with guide lines showing the catch - the same Cmd-snap the Position and Rotation controls use. The square is the topmost control, drawn over the rotation rings, scale box and Position handle; because it is small, the larger Position handle around it stays clickable, so both remain grabbable when they sit on the same spot (the default centre).

### Showing and hiding the controls

The inspector's **On-Screen Controls** toggle and its per-control pills (Position, Path, Scale, Rotation, Anchor) drive visibility. Canvas defaults the global toggle **on** but the Transform controls **hidden**, so the viewer stays clean; **Option-hold** reveals hidden controls as dimmed ghosts and **Option-click** toggles one. A **locked** layer hides its controls.

## Toolbar

A small floating toolbar sits over the preview in **both** the FCP viewer and the inspector mini-viewer - the same bar, the same buttons, and the same shared state, so a tool, grid toggle, or cell size set on one surface shows on the other. It is screen chrome: its settings are remembered but never change the render, only the editing overlay. Drag it anywhere by the **grip handle** on its left; the position survives zoom and size changes and is remembered separately per surface (the viewer and the mini each keep their own spot, since they differ in size and aspect).

A divider splits it into two groups. The buttons are icon-only; **hover any button for a localized tooltip** naming what it does.

- **Tools** - cursor, pen, rectangle, ellipse, with keyboard shortcuts **^V / ^X / ^B / ^G** shown on the button. The shortcuts work whenever either surface is focused. Selecting a tool (by click or shortcut) highlights it and stores it as the active tool. The **pen** tool draws paths (see below); the rectangle / ellipse tools are pending re-add, so picking one only sets the selection for now.
- **Grid controls** - see below.

### Grid

- **Grid** - toggles the overlay grid across the **whole preview** (it fills the letterbox margins too, not just the playback rectangle). Off by default. The grid is drawn as a subtle two-tone line (a darker edge under a lighter core) so it stays legible over both light and dark footage.
- **Auto grid spacing** - when on, keeps the cells readable by doubling the spacing as you zoom out so the grid never collapses into a grey wash; when off, the spacing stays fixed. On by default (the icon switches between the dotted "auto" and plain "fixed" grid glyph).
- **Cell size** - cycles the base cell size through **10 / 20 / 50 / 100** canvas pixels (so the grid is pinned to the canvas and scales on screen with zoom). The button shows the current value.
- **Snap to grid** - toggles snapping to the grid. Off by default. While it's on, dragging a layer's **Position** handle or its **Anchor** square pins the point to the nearest grid intersection (hold **Cmd** during a drag to override it with the usual centre / corner / keypose snapping instead). The grid spacing used is the one shown, so turn the grid on to see where things land. Snapping is shared infrastructure, so future path / shape editing will reuse it.

## Drawing with the pen tool

Pick the **pen** tool (**^X**, or the pen button on the toolbar) and the cursor becomes a pen nib. The transform gizmo hides while the pen is active, matching how a photo editor's pen tool works. Drawing works the same in the FCP viewer **and** the inspector mini-viewer (the same shared pen engine drives both).

- **Place anchors** - click to drop a corner point. The layer is created on the **first click**, so it appears in the layer list and renders straight away (a 20px red stroke for now); each further click extends it live.
- **Curves** - click and **drag** as you place a point to pull out its bezier tangent handles. Each anchor has two handles: an **in** handle that shapes the segment arriving at it and an **out** handle that shapes the segment leaving it. A plain click leaves both empty (a corner); a click-drag pulls both out, mirrored, so the curve passes smoothly through the point. While dragging a handle:
  - **Shift** - lock the handle to horizontal / vertical.
  - **Cmd** - snap its angle to 45° steps.
  - **Ctrl** - cusp: drop the **in** side so the segment arrives straight and only the outgoing side curves.

These are the same modifiers the Position motion-path handles use. (Freely retracting / breaking a handle after the fact is done with the cursor tool - see "Editing a path" below.)

- **Snap to grid** - when grid **Snap** is on, placed anchors snap to grid intersections and a dimmed **ghost dot** shows where the next click will land (including the first point). Handle drags stay free, and a press only becomes a curve once the mouse clearly moves, so a snapped click won't curve by accident.
- **Close the path** - click the **first anchor**; the cursor shows the close-shape glyph and the anchor highlights as you approach it. **Click-drag** the first anchor instead to smooth it, so the closing segment curves (the same drag that curves a freshly placed point); a plain click closes with a corner.
- **Finish an open path** - click the **last anchor** (it shows the same close-shape cursor + highlight), **double-click**, or press **Return**. Switching to another tool or selecting a different layer also confirms the path as-is (it isn't closed, just committed where it stands).
- **Cancel** - press **Esc** to discard the path you're drawing.

Anchors show as dots and tangent handles as smaller dots on lines, the same look as the Position motion path; the whole click(-drag) for a point is a single undo step, so Cmd-Z walks back anchor by anchor (the first undo also removes the layer). When you switch back to the **cursor** tool the path stays selected and its anchors stay editable (see below).

The pen tool is also context-sensitive on an existing selected path: clicking a **segment** inserts an anchor there (preserving the curve), and clicking either open **endpoint** continues drawing from that tip. Holding **Opt** over an anchor turns the cursor into a delete nib and removes that point.

Stroke style is a fixed 20px red for now; per-path stroke width / colour / fill are still to come.

## Editing a path (cursor tool)

With the **cursor** tool and a vector path selected, its anchors and tangent handles are editable directly - in both the FCP viewer and the inspector mini-viewer (the selection stays in sync between the two):

- **Move** - drag an anchor (grid-snaps like the pen) or drag a tangent handle (free; **Ctrl** breaks the handle into a cusp). Multiple selected anchors move together.
- **Select** - click an anchor; **Shift**-click to add/remove; drag an empty area over the path to **marquee**-select a group of anchors (**Opt**-drag subtracts).
- **Delete** - press **Delete**/**Backspace** to remove the selected anchors. The cursor-tool delete is "destructive" like Illustrator's Direct-Selection: deleting an anchor from a **closed** path **opens** it at that gap. (The pen tool's Opt-delete is the "smart" delete - the neighbours reconnect and a closed path stays closed.) Removing the last viable anchor deletes the layer.
- **Convert corner <-> smooth** - **double-click** an anchor to toggle it between a sharp corner (no handles) and a smooth point (auto-generated tangents).

Edits are per-keypose: on an animated path they change the keypose the playhead is parked on (anchors are read-only between keyposes). Each drag is one undo step.

## Rounding corners (live corner widget)

Every interior corner of a selected path shows a small accent **ring** just inside it (cursor tool only) - the same control style as the radius handle in the Rounded plugin. Drag the ring inward to round that corner, back out to sharpen it; it turns **red** at the maximum radius (half the shorter adjacent edge). The rounding is **per corner** and fully re-editable - drag the same widget again any time, or drag it to zero to restore the sharp corner. While a corner is rounded its stored tangent handles are hidden (the rounding owns that corner); they return when you clear the radius.

Because the radius is stored on the anchor (not baked into extra points), it **animates**: a corner can morph smoothly from sharp to rounded across Points keyposes. Rounding doesn't require a closed path - it works on any join.

## Motion blur

The inspector's motion-blur control applies the shared sample-accumulate blur to the layer animation (and the underlying content), the same engine the other Keyframeless plugins use.

## Pending re-add (tracked during the v3 rebuild)

- Per-layer **rotation** (lane + on-canvas gizmo).
- Per-layer opacity in the render.
- **Rectangle / ellipse** tools (the pen tool draws; these still only select).
- Stroke **styling** (width / colour UI - currently a fixed 20px red) and **fill**, plus the sketch (hand-drawn) render style and SVG import.
