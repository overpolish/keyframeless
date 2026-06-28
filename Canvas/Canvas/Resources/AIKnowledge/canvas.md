---
id: canvas
summary: What Canvas does
---

Canvas is a layer-based drawing and animation effect for Final Cut Pro. Each clip holds a stack of **layers** - vector shapes you draw, imported images and SVGs, and groups - and every layer can be animated independently with the shared Keyframeless timeline (Basic and Advanced timing, easing, motion blur).

Drop it on a clip from the Effects browser. Like the other Keyframeless plugins it works best on a compound or adjustment clip, so layers can extend past the clip's edges without being cropped.

## Layers

The **Layers panel** lists every layer top-to-bottom (topmost draws in front). Add layers by drawing with the pen tool, dragging out a rectangle or ellipse, or dragging image / `.svg` files from Finder onto the panel. Select a layer in the panel - or click it in the viewer with Auto-select on - to target the inspector's Animated dropdown and Constants at that layer. See the **Layers** topic for the full panel, selection, grouping, path-op and SVG details.

## What you can animate

- Every layer shares a common set of **transform** properties, plus drawing properties that depend on the layer type:
  - **Position** - where the layer sits in the frame. Two or more keyposes follow a path you can curve on the canvas.
  - **Scale** - resize by percentage (X and Y).
  - **Rotation** - spin around the layer's anchor (Z is the usual in-plane spin; X and Y tilt it in 3D).
  - **Anchor** - the pivot Rotation and Scale swing around (defaults to the layer centre). Groups store their anchor so moving a member never drags the pivot.
  - **Opacity** - fade the layer in or out.

For a **vector path** you can also animate the **Stroke** (width, caps/joins, dashes, end markers, marching-ants offset, and a solid or gradient colour), the **Fill** (solid or gradient, hachure styles), a hand-drawn **Sketch** roughness, and **Draw On** (reveal the stroke over time, per contour). For an **image** the Fill becomes a tint / hachure overlay. Groups animate the transform set only.

## Timeline

The timeline is a stable **global** view: it shows every layer's animated properties at once, all editable, regardless of which layer is selected. Selection only drives the Animated dropdown and the Constants popover (which layer those target). Use **Basic** for quick in/hold/out timing shared across layers, or **Advanced** for per-lane keyposes and curves. The on-screen controls (Position handle and motion path, Scale box, Rotation rings) edit the selected layer directly in the viewer.

## What the assistant can do

Describe an animation in plain language and the assistant edits the timeline for you - across one layer or several at once (for example "slide the logo in from the left and fade everything else up"). It can also answer questions about how Canvas, the timeline, and the on-screen controls work.
