---
id: shader
summary: What Mirage does
---

- Mirage runs a **Shadertoy-style GLSL shader** on a clip. Apply it to footage from the Effects browser and the shader can read that clip (as `iChannel0`) and process it - blur, displace, tint, feed it through a simulation - or ignore it and draw a procedural look over it. To use it as a pure generator (nothing underneath), apply it to an adjustment layer or a solid. Everything animates on the keyframeless timeline, so the Timing sections (Basic, Advanced, easing, motion blur) apply to every control.
- Mirage can run a **chain of shaders** on one clip: the strip of boxes above the controls is the **rack**, and each shader takes the previous one's output as its input, with the last one writing the frame. One shader is simply a rack of one, and behaves exactly as it always has.
  - **Click a box** to work on that shader - the code editor, the controls, the Color panel, the on-screen controls and the AI all follow the selection.
  - **+** at the end of the chain adds a shader from the browser, and dragging a box along the strip changes the order they run in. Each box's **Enabled** switch is a keyframable bypass - a shader that is off is skipped whole and the chain flows past it.
  - The mini viewer can preview the chain **up to here** or one shader **solo** (fed the original clip). Those only change the mini viewer, never Final Cut's viewer, and aren't saved with the project.
- The look is entirely defined by the **shader code** you paste or write - see the custom-shader doc for the shader language, built-in inputs (`iTime`, `iChannel0`, ...), and multi-pass buffers.
- A shader exposes **its own controls** (sliders, colours, points, on-screen handles) by annotating its uniforms with `// #` directives - see the directives doc.
- A shader can read a **second clip** on `iChannel1` (the "To" image well), so it can do real **transitions** - a genuine A-to-B blend, not just a distortion of one clip - and picture-in-picture. Shaders from the **gl-transitions.com** catalogue paste in and run unmodified. Because `progress` becomes a lane on the timing engine, those transitions can be eased and reshaped, which the GL Transitions spec itself can't express (it's linear-only). See the custom-shader doc.
- A shader can **react to the audio in your project** with the `#audio` directive: publish the music or dialogue from Sonar (the free tab in Keyframeless X), pick it from the shader's menu, and the look moves to it - on playback and in the export. See the audio-sonar and audio-shader-directive docs.
- Saving a shader to the browser tags it with a **category** - one of **Generator** (draws its own look), **Audio** (reacts to a `#audio` binding), **Filter** (processes the clip on `iChannel0`), **Transition** (blends two clips across `iProgress`), or **Layout** (draws a clip into one region - picture-in-picture, split, quarters - and stays transparent elsewhere with `// #alpha`). It's a save-time label, not a code setting: nothing in the shader source changes with it, and Generator is the default. The browser filters by category (the icon pills above the list) and badges each card with its type. A shader that does more than one thing is filed under whichever the author leads with.

## The rack (a chain of shaders)

One Mirage instance hosts an ordered list of shader **entries**. Entry k+1 reads entry k's output as its `iChannel0`, so an entry that samples the source clip is really sampling whatever the entries before it produced. The last enabled entry writes the frame. The "To" well, audio bindings and every other input are unchanged.

- The rack lives as a strip of boxes between the mini viewer and the parameter rows in the static-values popover. Exactly one box is selected, and the selection **scopes the whole rest of the UI**: the code editor edits that entry's shader, the parameter rows show that entry's controls, the Color panel grades on that entry, the on-screen controls belong to that entry, and the built-in AI reads and writes that entry's code only. An instruction like "make it warmer" therefore applies to the selected entry, not the chain.
- Each entry has an **Enabled** toggle that is an ordinary animatable lane, so a bypass can be keyframed. A disabled entry is skipped whole - its input is passed straight to the next entry - rather than rendered and discarded.
- Entries are added with the **+** at the end of the strip (which opens the template browser), removed, and reordered by dragging along the strip. The rack always keeps at least one entry.
- The mini viewer's per-entry preview modes - **up to here** (the chain truncated after that entry, skips still applied) and **solo** (that entry alone, fed the original clip) - are session-only. They are never persisted, never an undo entry, and never change what Final Cut's viewer shows.
- A project with a single shader is a rack of one and renders exactly as it did before racking existed, so nothing in this doc changes how an unracked shader is written.

## Built-in controls (opt-in)

Three controls the engine provides rather than the shader. A shader asks for them with a standalone directive; one that doesn't gets neither the control nor its effect:

- `// #speed` - **Speed**, a motion-rate multiplier for `iTime` (0 freezes, higher is faster).
- `// #seed` - **Seed**, offsetting where `iTime` starts, for per-clip variety (non-animatable).
- `// #grain` - **Grain** / **Grain Size**, a film-grain overlay on top of the shader's output (breaks 8-bit banding, scales up to stylistic grain).

Every other control - colours, amounts, positions, angles - is something the shader itself declares via a directive. A shader with no directives at all shows just the code editor.

## Groups

Controls are grouped in the inspector. A control with no `group=` goes to **Options**; `group="Name"` (or `group={"Name", "sf.symbol"}` to set the group's icon) puts it anywhere you like. Groups appear in a fixed order - **Shader**, **Audio**, **Colors** - followed by the shader's own groups in the order it first names them. Colours, audio and gradients always use their own groups and can't be moved. See the directives doc.

## On-screen controls

A shader's declared controls can also draw draggable handles on the viewer and mini-viewer: a **point** handle (`#point`), a radius **ring** or **box** (`#float` / `#percent` / `#int` / `#multi`), and **rotation** rings (`#angle` / `#multi`). Each is hideable to declutter: use the inspector's On-Screen Controls tick and its settings cog, or Option-click a control on the viewer/mini-viewer to hide it (Option-hold reveals hidden ones as dimmed ghosts). See the directives doc for how to declare them and the shared on-screen-control visibility docs for the full hide/reveal behaviour.
