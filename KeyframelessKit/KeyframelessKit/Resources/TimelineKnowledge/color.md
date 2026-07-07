---
id: color
summary: Color property - Dynamic, Solid, and Gradient modes shared across plugins
---

# Color: Dynamic, Solid, and Gradient

Color is a shared property that any plugin can adopt, so it looks and behaves the same everywhere (a plugin can have more than one - for example a fill colour and a stroke colour). What the colour _applies to_ depends on the plugin: in Glow it tints the glow. The control, its modes, and the way it animates are identical because they are the same shared code.

A Color group has a **Mode** selector and, depending on the mode, either a colour swatch or a gradient editor. Mode itself is structural: it is chosen in the constants / keypose editor and is **not** animated (you do not keyframe from Solid to Gradient). The colour _within_ a mode is what animates.

## Modes

- **Dynamic** (the default, when a plugin offers it) - the colour is taken from the clip itself rather than a fixed value, so it follows the source content. There is nothing to edit and nothing to animate.
- **Solid** - a single colour. Click the swatch to open the colour picker. Solid is animatable.
- **Gradient** - a blend across several colour stops, with a **Type** (Radial or Linear) and, for Linear, an **Angle**. Gradient is animatable.

Not every plugin offers Dynamic; Solid and Gradient are always available.

## Editing a gradient

The gradient lives in one row: the **Radial / Linear** type toggle, an **Angle** knob and field (shown only for Linear - Radial ignores angle), and the **gradient bar**.

- **Add a stop** - click an empty spot on the bar.
- **Move a stop** - drag it along the bar.
- **Edit a stop's colour** - click the stop to open the colour picker.
- **Midpoint** - drag the small marker between two stops to bias the blend toward one side.

## Animating colour

Solid and Gradient can be moved into the animated timeline like any other property (the "move to animated" button). Once animated they show on the graph:

- **Solid** plots three lines - the **red, green, and blue** channels - so you can see the colour changing over time.
- **Gradient** plots up to two derived lines: the **angle** (for Linear) and a single weighted **signature** of the stops, so a change in the stops or their positions reads as a moving line. (The individual stop colours are not plotted channel by channel; the signature stands in for "the gradient is changing".)

Interpolation is structural, not a naive number-by-number blend: the gradient **Type is held** (it does not morph Radial into Linear mid-animation), the **Angle eases**, and the **stops blend** even when two keyposes have different numbers of stops (they are resampled onto a common set of positions so the ends stay accurate).

Because Type must stay editable after you animate, the **Radial / Linear** toggle still appears in the keypose editor. Changing it there applies to **every** keypose at once (it is a single structural choice, not a per-keypose value).

## Modulating the gradient angle

A Linear gradient's **Angle** is the one part of a colour that can be wiggled with hold modulation (Wiggle / Oscillate / Handheld), so the gradient direction can oscillate over a hold. Open the modulation control on a gradient hold and enable the **Angle** toggle. Radial gradients and solid colours have no modulation - there is nothing meaningful to wiggle. The angle wiggles by a uniform number of degrees regardless of its base value, and crossing 0 / 360 is seamless.

## Where it shows up

- The Color group appears wherever the plugin places it (often a "Color" category alongside the plugin's other properties).
- In the **Basic** timeline a gradient is a single top-level item in a phase's "applies to" set (it eases or holds with the phase like any property); it never expands into its raw numeric components.
- In the **Advanced** timeline each animated colour gets its own track with the graph lines described above.
