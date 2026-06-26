# Layers

Canvas is a layer-based drawing/animation effect. Each clip holds a stack of **layers** (shapes, imported images, SVGs, and groups). The **Layers panel** opens to the left of any value/constants editing popover and lists every layer top-to-bottom (topmost layer draws in front).

A layer is a `KKBezierPath`. The whole stack is serialized to a hidden `kParamLayerData` param (base64 of `+[KKBezierPath blobFromPaths:]`); the Layers panel reads and writes that blob directly and rebuilds its rows. (There is no reactive store / OSC pump in this version - those were removed in the v3 rebuild.)

## Adding layers

- **Drag image files** (png, jpg, jpeg, webp, heic, tiff, gif, bmp) from Finder onto the Layers panel to add them as image layers. A drop line shows where the new layers will be inserted in the stack. The panel stays open while you switch to Finder (an outside-click only dismisses it when it lands in the host app).
- **Draw** a path with the **pen** tool, or drag out a **rectangle** / **ellipse** with the shape tools (see "Drawing with the pen tool" and "Creating shapes" below).
- **Drag SVG files** from Finder onto the Layers panel to import them as editable vector paths (see "Importing SVG" below).

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
- It respects the layer's transform, so a moved / scaled / rotated layer is picked where it actually appears - including **3D depth**: when a group's X/Y tilt swings a lower layer physically in front, clicking there selects that front layer (it picks in the same front-to-back order the layers are drawn, not raw list order).
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

## Stroke

Vector paths have a **Stroke** group in the inspector (images and groups don't - they have no stroke). It holds:

- **Enabled** - a checkbox that turns the path's stroke on or off. When it's off the stroke stops rendering and the rest of the Stroke group's controls drop out of every timeline surface (the constants/keypose popovers, the Animated dropdown, the lane filter, and the Basic/Advanced graphs) until you turn it back on - the toggle is the single source of truth.
- **Stroke Width** - a two-field width in pixels with a **Start** and an **End**, whole numbers, **aspect-linked by default**. Linked, the two move together and the stroke is a uniform width. **Unlink** them (the link glyph on the row) and set Start ≠ End to **taper** the stroke - it interpolates from the Start width at the beginning of the path to the End width at the end, along the path's length. The taper is computed per contour, so a boolean / multi-contour path tapers each subpath; on a closed shape the width steps from End back to Start at the point where it closes.
- **Stroke colour** - a **Mode** pill (Solid / Gradient) plus the matching editor: a colour **swatch** for Solid, or a **gradient** editor (stops, Radial / Linear, angle) for Gradient. Solid colour and the gradient both **animate** (add them to the Animated dropdown); Mode itself is a structural choice, not animated. The whole colour sub-group is gated by the **Enabled** toggle, like the rest of the Stroke group.
- **Line Cap** - how an **open** path's ends are drawn, as a glyph pill: **Butt** (flat at the end), **Round** (semicircle), **Square** (extends half a stroke-width past the end). Only shown when the path actually has an open end (a closed shape has no caps).
- **Line Join** - how corners are drawn, as a glyph pill: **Miter** (sharp point), **Round** (arc), **Bevel** (flat cut). Applies to every corner, open or closed. Both Cap and Join are structural choices (not animated).
- **Start Marker** / **End Marker** - an endpoint decoration for each **open** end of the path, as a glyph pill: **None**, **Arrow** (filled triangle), **Circle**, **Square**, **Arrowhead** (open chevron), **Line** (perpendicular tick). The marker type is a structural choice (not animated). Markers are part of the stroke: they take the stroke's **colour / gradient** (the gradient spans the stroke and its markers as one shape) and are clickable like the stroke. Only shown when the path has an open end (a closed shape has none). Each marker row carries its own width:
  - **Start Marker Width** / **End Marker Width** - the marker size as a **percentage of the stroke width** (default 300%). The slider runs to 500% and the field accepts larger values. These **animate** (add them to the Animated dropdown), so a marker can grow or shrink over the clip while its type stays put. A width row only appears when its marker is set to something other than None.
- **Draw On Start** / **Draw On End** / **Draw On Offset** - a progressive **write-on** reveal that trims the stroke by length. Start/End are the visible span as a **percentage** of the path: the stroke shows only from **Start** to **End** (default 0% -> 100% = the whole shape). Keyframe **End** from 0 to 100 to draw the line on; keyframe **Start** to wipe it off from the front. **Offset** (0% default) rotates where the visible window begins around the path, so a shorter span can **travel along the path** - great for a moving highlight or sweeping an arrow around a box outline. Its slider is 0-100% but the field is unbounded, so you can keep cranking it to spin the reveal round and round (forwards or backwards) infinitely. All three **animate** (add them to the Animated dropdown); animate Offset to make the window sweep. Works on a single open **or** closed contour (a circle/rectangle draws on around its loop), and on a **multi-contour** path each contour reveals independently with the same Start/End/Offset - so every branch of a centerline-traced shape writes on together (endpoint markers are skipped on a multi-contour path, which has no single pair of ends). The line always shows exactly the Start->End span (Start == End shows nothing).
  - **Caps and endpoint markers follow the reveal.** Line caps sit on the revealed tips. An **Arrow** / **Arrowhead** rides the moving tip pointing in the drawing direction (it grows in as the line leaves the start and leads the tip). A **Circle** / **Square** / **Line** tick sits at the path's end and animates in (from one stroke-width up to its size) as the line reaches it. With **Offset** animating, the markers ride the moving window's two ends, easing out and back in as they cross the path's endpoints; markers stay visible throughout the spin.
- **Stroke Style** - a pill choosing **Solid**, **Dashed**, or **Dotted**. It's a structural choice (not animated). Picking Dashed or Dotted reveals the matching size controls:
  - **Dash Length** / **Dash Gap** (Dashed) - the length of each dash and the gap between dashes, in pixels.
  - **Dot Gap** (Dotted) - the gap between dots, in pixels (the dot size follows the stroke width).
  - **Marching Ants Speed** (Dashed or Dotted) - animates the dashes/dots crawling along the path (the classic "marching ants" border). It's the number of dashes-per-second the pattern advances: **0** holds the pattern still, higher values march faster, and it follows the playhead so it only moves during playback or scrubbing. This one **animates** (add it to the Animated dropdown) so you can ramp the march speed up or down. Dashes and dots follow the stroke exactly, including around corners and along a taper, and a dashed stroke can still use a Solid or Gradient colour.

Stroke Width and the colour are ordinary animatable lanes: constant by default, or add them to the Animated dropdown to keypose them over the clip with the usual Basic / Advanced timing. They edit whichever path is selected in the Layers panel, and the rendered width is resolution-correct (it scales down correctly in browser thumbnails). Hit-testing follows the actual drawn stroke, so a tapered stroke stays clickable along its real shape, fat end and thin end alike.

The **gradient** maps onto the stroke pivoting on the layer's centre: **Linear** runs along the angle (0° up, 90° right, 180° down) and spans the layer so it always reaches both end colours; **Radial** runs as a circle from the centre out to the ends. Colours are rendered colour-accurate against the editor swatch. In the Advanced graph an animated solid colour plots its **R / G / B** channels as separate red/green/blue lines (alpha is edited in the swatch, not graphed).

## Fill

Vector paths and images have a **Fill** group in the inspector (groups don't - they only transform their members). Fill suits **closed** shapes (a rectangle, ellipse, or any path you've closed); an open path's fill closes the gap implicitly. A path's fill is drawn **under its stroke**, so a filled-and-stroked shape shows the stroke sitting on top of the fill. It holds:

- **Enabled** - a checkbox that turns the fill on or off. Like the Stroke group, when it's off the rest of the Fill controls drop out of every timeline surface (constants/keypose popovers, the Animated dropdown, the lane filter, the Basic/Advanced graphs) until you turn it back on.
- **Fill colour** - a **Mode** pill (Solid / Gradient) plus the matching editor: a colour **swatch** for Solid, or a **gradient** editor (stops, Radial / Linear, angle) for Gradient. Both **animate** (add them to the Animated dropdown); Mode is a structural choice, not animated. The gradient maps the same way the stroke's does - Linear runs along the angle and spans the layer, Radial runs as a circle from the centre out. The fill silhouette is **antialiased** (multisampled), and a filled shape is **hit-testable**: click anywhere inside it (not just on the stroke) to select the layer, matching the actual drawn fill including concave shapes and the holes of a compound path.
- **Fill Style** - a glyph pill choosing how the area is filled: **Solid** (a flat filled shape), or one of four hatch patterns - **Hachure** (parallel diagonal lines), **Cross** (cross-hatch, two crossing sets), **Zigzag** (a single zigzag line per row), **Dots** (a grid of dots). It's a structural choice (not animated). The hatch patterns are drawn in the fill colour - **including the gradient**, which runs across the lines just as it would across a solid fill. Picking any non-Solid style reveals the pattern controls:
  - **Fill Gap** - the spacing between hatch lines (or dots), in pixels.
  - **Fill Angle** - the hatch direction in degrees, edited with a **dial** (the same circular knob as the Transform Rotation).
  - **Fill Weight** - the thickness of the hatch lines (or the dot size), in pixels.
- **Fill Amount** (images only, Solid style) - **images** get the Fill group too, where a **Solid** fill acts as a **tint**: this 0-100% amount colourises the picture toward the fill colour (or gradient), 0% leaving it untouched. It only appears for an image with a Solid Fill Style.

On an **image**, a non-Solid Fill Style **replaces** the picture with the hatch pattern, clipped to the image's own **silhouette** (its alpha) rather than its bounding box - so a hachured cut-out keeps its shape and reads as the pattern in the fill colour. A Solid image fill tints instead (see Fill Amount).

## Sketch

The **Sketch** group renders a layer's stroke and fill in a **hand-drawn** style (the rough.js look): the geometry is wobbled and the line bowed as if sketched by hand. It appears where there's something to roughen - on a **vector path** when its **Stroke OR Fill** is enabled, and on an **image** only when its (hachure) **Fill** is enabled; never on a group. It holds:

- **Enabled** - the master checkbox. Off (the default) leaves everything crisp and hides the rest of the group; on, it roughens the layer and reveals the controls. Like Stroke/Fill, when it's off the rest of the group drops out of every timeline surface.
- **Sketch Roughness** - how far the line jitters from true, 0-3 (default 1). 0 is effectively crisp; higher is scratchier. **Animates** (add it to the Animated dropdown) so a shape can settle from rough to clean over the clip.
- **Sketch Bowing** - how much each straight segment **bows** (curves) between its ends, 0-3 (default 1). 0 keeps segments straight (just jittered); higher makes them visibly arc. Animates.
- **Sketch Strokes** - a **Single** / **Double** pill: Single draws the line once; Double (default) draws a second lighter pass slightly offset, for the doubled, sketched-over look.
- **Sketch Seed** - the random seed, a value with a **re-roll** (dice) button rather than a slider. The jitter is otherwise **stable across frames** (it won't crawl or flicker during playback); re-roll the seed to get a different hand-drawn variation of the same shape.

The roughness scales with the stroke width, and the look is resolution-correct (it matches in browser thumbnails). A hand-drawn **fill** wobbles its outline; a **hachure** fill draws each hatch line as a hand-drawn stroke; on an image, the hachure lines roughen while the picture's silhouette stays put.

## Toolbar

A small floating toolbar sits over the preview in **both** the FCP viewer and the inspector mini-viewer - the same bar, the same buttons, and the same shared state, so a tool, grid toggle, or cell size set on one surface shows on the other. It is screen chrome: its settings are remembered but never change the render, only the editing overlay. Drag it anywhere by the **grip handle** on its left; the position survives zoom and size changes and is remembered separately per surface (the viewer and the mini each keep their own spot, since they differ in size and aspect).

Dividers split it into groups. The buttons are icon-only; **hover any button for a localized tooltip** naming what it does.

- **Tools** - cursor, pen, rectangle, ellipse, with keyboard shortcuts **^V / ^X / ^B / ^G** shown on the button. The shortcuts work whenever either surface is focused. Selecting a tool (by click or shortcut) highlights it and stores it as the active tool. The **pen** tool draws paths and the **rectangle** / **ellipse** tools drag out shapes (see below); both work in the FCP viewer and the inspector mini-viewer.
- **Path operations** - a group that appears only when the selection makes it relevant (see Path operations below).
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

A new path starts with a 20px red stroke. Its **width** (with an optional Start->End taper) and **colour** (solid or gradient) are now per-path, animatable properties - see **Stroke** above; close the path and it can take a **Fill** too (see **Fill** above).

## Creating shapes (rectangle / ellipse tools)

Pick the **rectangle** (**^B**) or **ellipse** (**^G**) tool and **drag a box** over the preview to drop a new closed shape layer; release to create it (one undo step) with the new layer selected. Like the pen, the transform gizmo hides while a shape tool is active, and shapes draw the same in the FCP viewer **and** the inspector mini-viewer. While dragging:

- **Shift** constrains to a **square** / **circle** (equal on-screen width and height).
- **Opt** draws from the **centre** out instead of corner to corner.
- With **Snap to grid** on, the box corners snap to the grid.

A new shape inherits the same default look as a pen path (a 20px red stroke). A rectangle is a plain four-corner path, so the **live corner widget** rounds it into a rounded rectangle with no extra steps (see below); because the radius is stored per corner, a rectangle can even animate from sharp to rounded across Points keyposes. Both shapes are fully editable afterwards with the cursor tool (move anchors, pull tangent handles, add/remove points) - they are ordinary paths.

## Selecting and moving on the canvas (cursor tool)

With the **cursor** tool you can select and move layers directly on the canvas - in both the FCP viewer and the inspector mini-viewer (the selection stays in sync with the Layers panel). What the on-screen controls show follows the selection: nothing selected draws no controls; one **image** or **group** shows its transform gizmo (Position / Scale / Rotation / Anchor); one **path** shows its point-edit controls + the path-ops toolbar; **two or more** layers show a dimmed selection box around each (plus the path-ops toolbar when at least two are paths).

- **Marquee-select layers** - drag a rubber-band over an empty part of the canvas; every layer it fully encloses is selected. **Shift**-drag adds to the current selection. (With **Auto-select** off you can also start the marquee over a layer's body.)
- **Click to select** - click a layer (Auto-select on) to select it; **Shift / Cmd**-click adds or removes it from a multi-selection.
- **Click empty space to deselect** - a plain click on empty canvas clears the selection (no controls shown).
- **Drag a layer's body to move it** - drag the body of a selected layer to move the whole selection together; images shift their **Position**, paths shift their **points**. Like the on-screen handles, a move only applies where the layer is editable at the playhead (constant, or parked on a keypose). One drag is one undo step.

When exactly one editable **path** is selected, a marquee instead selects that path's **anchors** (see below); it only routes to layer-select when the box encloses a _different_ layer.

## Editing a path (cursor tool)

With the **cursor** tool and a vector path selected, its anchors and tangent handles are editable directly - in both the FCP viewer and the inspector mini-viewer (the selection stays in sync between the two):

- **Move** - drag an anchor (grid-snaps like the pen) or drag a tangent handle (free; **Ctrl** breaks the handle into a cusp). Multiple selected anchors move together.
- **Select** - click an anchor; **Shift**-click to add/remove; with that single path selected, drag an empty area over it to **marquee**-select a group of its anchors (**Opt**-drag subtracts). Enclosing the whole shape selects all its anchors.
- **Delete** - press **Delete**/**Backspace** to remove the selected anchors. The cursor-tool delete is "destructive" like Illustrator's Direct-Selection: deleting an anchor from a **closed** path **opens** it at that gap. (The pen tool's Opt-delete is the "smart" delete - the neighbours reconnect and a closed path stays closed.) Removing the last viable anchor deletes the layer.
- **Convert corner <-> smooth** - **double-click** an anchor to toggle it between a sharp corner (no handles) and a smooth point (auto-generated tangents).

Edits are per-keypose: on an animated path they change the keypose the playhead is parked on (anchors are read-only between keyposes). Each drag is one undo step.

## Rounding corners (live corner widget)

A genuine sharp corner of a selected path shows a small accent **ring** just inside it (cursor tool only) - the same control style as the radius handle in the Rounded plugin. To keep detailed paths readable the ring is only offered where rounding makes sense: smooth (tangent-continuous) points and near-straight joins don't get one, but a corner that already has a radius set always shows its ring so you can still adjust or clear it. Drag the ring inward to round that corner, back out to sharpen it; it turns **red** at the maximum radius (half the shorter adjacent edge). The rounding is **per corner** and fully re-editable - drag the same widget again any time, or drag it to zero to restore the sharp corner. While a corner is rounded its stored tangent handles are hidden (the rounding owns that corner); they return when you clear the radius.

**Round several corners at once**: select multiple anchors first (Shift-click them, or marquee-drag over the path), then drag any one of the selected corners' rings - every selected corner takes the same radius together, in a single undo. Each corner still clamps to its own maximum, so a tighter corner rounds as far as it can (and turns red) while the others keep going; anchors that can't be rounded (open-path endpoints, near-straight joins) are left alone.

Because the radius is stored on the anchor (not baked into extra points), it **animates**: a corner can morph smoothly from sharp to rounded across Points keyposes. Rounding doesn't require a closed path - it works on any join.

## Path operations

When you select vector paths, extra buttons appear in the toolbar (in **both** the viewer and the mini-viewer) for combining or reshaping them. Select layers the usual way - in the Layers panel, or by clicking them in the viewer / mini with **Auto-select** on (Shift / Cmd-click to add more). The buttons only show when they apply:

- **Stroke to path** - shows when a selected path has a stroke. Converts each selected stroke into a filled outline shape (the original stroke is turned off), so you can then fill or boolean it like any other shape.
- **Centerline** - shows when a **filled** path or an **image** is selected; the inverse of Stroke to path. Traces the shape down to its **centerline** (the medial axis) as an editable stroke. Works on a filled vector shape **or** an image's silhouette (a transparent-background outline keyed by its alpha; a dark line on a solid background keyed by its luminance). It recovers the line's thickness as the stroke width, and picks the detail level **automatically** - it re-traces at a few settings and keeps the one whose stroke best overlaps the source (so a fine outline like a state map stays crisp while a thick band stays smooth). A closed outline closes into a loop; open ends extend out to the shape's tips; a branchy shape becomes a **multi-contour** stroke (one contour per branch, which then supports per-contour draw-on). A vector source is consumed (like a boolean); an **image** is kept, with the stroke added above it.
- **Union / Subtract / Intersect / Exclude** - show when **two or more** paths are selected. Union merges them into one; Subtract cuts the upper paths out of the bottom one; Intersect keeps only the overlap; Exclude keeps only the non-overlapping parts. The operands are replaced by a single result that inherits the bottom path's style.

**Hover preview**: hovering a path-operation button previews the outcome directly on the canvas - the paths that will be **removed** are shown as a translucent **red** fill and the result that will **remain** as a translucent **green** fill (concave shapes and the holes from a boolean fill correctly), so you can see exactly what you'll get before committing. The preview shows in both the viewer and the mini-viewer and clears when you move off the button.

The operations run on the paths' stored geometry, so a per-layer move / scale / rotate isn't baked into the result (matching how the pre-v3 version worked). A path with **rounded corners** is expanded to its rounded outline before the operation, so the rounding is honoured in the result. When a boolean produces several disconnected regions the result stays a single **multi-contour** layer - its subpaths render, edit, round and delete-points independently (they don't get joined together).

## Importing SVG

Drag an **`.svg`** file from Finder onto the Layers panel (alongside images - the same drop line shows where it lands). Each shape in the file becomes a vector path layer: a single-shape SVG imports as one path named after the file; a multi-shape SVG imports as a **group** (named after the file) with one child path per shape, stacked to match the SVG's paint order. The art is fitted into the canvas, aspect-correct and centred. Supported elements: `<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polygon>`, `<polyline>`; anything else is skipped.

Imported paths are ordinary editable paths. A small, simple SVG can be point-edited like a pen path. A **detailed** outline (over ~250 anchors) is flagged in the layer list with a distinct accent path glyph (hover it for the explanation) and behaves like an image: it shows the transform gizmo (move / scale / rotate) by default instead of the per-anchor controls, since hand-editing thousands of points isn't practical and performance would be slow.

## Motion blur

The inspector's motion-blur control applies the shared sample-accumulate blur to the layer animation (and the underlying content), the same engine the other Keyframeless plugins use.

## Pending re-add (tracked during the v3 rebuild)

- Per-layer **rotation** (lane + on-canvas gizmo).
- Per-layer opacity in the render.
