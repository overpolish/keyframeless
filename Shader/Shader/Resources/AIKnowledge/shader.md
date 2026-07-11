---
id: shader
summary: What Shader does
---

- Shader is an animated effect: apply it to a clip from the Effects browser and it fills the clip with a moving, procedural look. To use it as a generator (nothing underneath), apply it to an adjustment layer or a solid. Everything animates on the keyframeless timeline, so the Timing sections cover Basic, Advanced, easing, and motion blur. The **Custom** type can also read the clip it's applied to as `iChannel0` (see the custom-shader doc), so it can process footage, not just overlay it.
- Pick a look with **Type**. There are 12 built-in generative types plus **Custom**:
  - **Mesh** (a smooth multi-colour mesh gradient), **Dithering**, **Grainy**, **Warp**, **Neuro**, **Simplex**, **Metaballs**, **God Rays**, **Fluid**, **Wisp**, **Silk**, **Strata**.
  - **Custom** turns Shader into a blank canvas for a pasted Shadertoy/GLSL shader - see the custom-shader doc for that whole feature.

## Shared controls (all types)

- **Speed** - motion-rate multiplier (0 freezes, higher is faster).
- **Seed** - offsets the start point, for per-clip variety (non-animatable).
- **Origin** - an X/Y point that positions the pattern on the canvas (draggable handle).
- **Scale** - per-axis zoom (%), aspect-linkable, driven by the on-screen box.
- **Rotation** - Z rotation, driven by the on-screen ring.
- **Grain** / **Grain Size** - a core film-grain overlay (subtle by default; breaks 8-bit banding and scales up to stylistic grain). Applies to every type, Custom included.
- **Colours** - a dynamic palette of swatches (add/remove, up to 10) with a palette generator; the built-in types draw their colours from it.

Most types add a few of their own controls under their Type section. `Speed`, `Origin`, `Scale`, `Rotation`, `Grain` and the palette are shared across all of them.

## On-screen controls

Three OSC handles on the viewer: the **Origin** point, the **Scale** box, and the **Rotation** ring. Each can be hidden to declutter (the inspector's On-Screen Controls tick + its settings cog, or Option-click a control on the viewer/mini-viewer to hide it; Option-hold reveals hidden ones as dimmed ghosts). See the shared on-screen-control visibility docs for the full behaviour.
