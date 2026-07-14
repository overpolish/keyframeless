---
id: shader
summary: What Shader does
---

- Shader runs a **Shadertoy-style GLSL shader** on a clip. Apply it to footage from the Effects browser and the shader can read that clip (as `iChannel0`) and process it - blur, displace, tint, feed it through a simulation - or ignore it and draw a procedural look over it. To use it as a pure generator (nothing underneath), apply it to an adjustment layer or a solid. Everything animates on the keyframeless timeline, so the Timing sections (Basic, Advanced, easing, motion blur) apply to every control.
- The look is entirely defined by the **shader code** you paste or write - see the custom-shader doc for the shader language, built-in inputs (`iTime`, `iChannel0`, ...), and multi-pass buffers.
- A shader exposes **its own controls** (sliders, colours, points, on-screen handles) by annotating its uniforms with `// #` directives - see the directives doc.

## Shared controls (always present)

- **Speed** - motion-rate multiplier for `iTime` (0 freezes, higher is faster).
- **Seed** - offsets where `iTime` starts, for per-clip variety (non-animatable).
- **Grain** / **Grain Size** - a core film-grain overlay applied on top of the shader's output (subtle by default; breaks 8-bit banding, scales up to stylistic grain).

Any other control - colours, amounts, positions, angles - is something the shader itself declares via a directive. A shader with no directives shows just these shared controls plus the code editor.

## On-screen controls

A shader's declared controls can also draw draggable handles on the viewer and mini-viewer: a **point** handle (`#point`), a radius **ring** or **box** (`#float` / `#percent` / `#int` / `#multi`), and **rotation** rings (`#angle` / `#multi`). Each is hideable to declutter: use the inspector's On-Screen Controls tick and its settings cog, or Option-click a control on the viewer/mini-viewer to hide it (Option-hold reveals hidden ones as dimmed ghosts). See the directives doc for how to declare them and the shared on-screen-control visibility docs for the full hide/reveal behaviour.
