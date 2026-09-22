# Magic Move

A Motion/FCP effect that uses native keyframes for values and arrival times, with incoming transition timing controlled in the inspector.

## Inspector

| Property | Components | Display units | Default |
| --- | --- | --- | --- |
| Scale | X, Y, with proportional linking | Percent | 100, 100 |
| Position | X, Y | Pixels relative to the image centre | 0, 0 |
| Rotation | X, Y, Z | Degrees | 0, 0, 0 |
| Opacity | Scalar | Percent | 100 |
| Blur | Scalar | Pixels of Gaussian sigma | 0 |
| Anchor | X, Y | Pixels relative to the image centre | 0, 0 |

Click a value to edit it or drag to scrub it. Use the host's keyframe buttons to create, navigate, and remove keyframes. Selecting a property row shows its curves and timing controls. The graph also shows linked properties, with matching axis colours. Click or drag in the graph to move the playhead; move keyframes using the host's keyframe editor.

Anchor sets the pivot for scale and rotation. Moving it alone at identity does not move the image. Pixel values use full-resolution source dimensions, including when the host renders a reduced-resolution preview.

## Transition timing

Each keyframe controls the transition **into itself**. Between two keyframes, Duration and Easing edit the next keyframe. At an exact keyframe, they edit that keyframe's incoming transition. The first keyframe has no incoming transition.

Duration holds the preceding value until the transition needs to begin. If the requested duration exceeds the gap, the engine uses the available gap without changing the saved duration. A zero duration cuts at arrival. **Use available time** fills the gap with the selected easing and retains the fixed duration for when the option is turned off.

Easing choices are Smooth, Linear, Ease In, and Ease Out. Before and after the animated sequence, the endpoint value holds. Properties with no keyframes use their static value.

## Match In/Out

Right-click a property label and choose **Match In/Out** to pair its first and last keyframes. The endpoint values mirror each other, so editing either one updates the other. With three or more keyframes the first incoming transition and the final one also share Duration, Use available time and Easing. Interior keyframes stay independent, and Added Motion never pairs, because it belongs to the keyframe that precedes a gap.

Enabling the setting applies the first endpoint to the last, so the entrance you authored defines the exit. With a single keyframe, enabling creates the opposite endpoint: an Out on the effect's last frame, or an In at the start when the sole keyframe already sits on the last frame. A property with no keyframes has nothing to pair, so the menu item is unavailable.

Matching is per property and is not shared with linked properties. A linked partner still follows the timing of a matched endpoint, because linking shares timing, but its own Match In/Out stays as you left it. Endpoints are positional, so inserting or moving keyframes re-pairs the keyframes the property ends up with. Deleting an endpoint leaves the remaining keyframe alone rather than recreating a partner.

## Added Motion

Added Motion belongs to the keyframe at the start of the selected gap. Choose None, Wave, Wiggle, or Handheld, then adjust Amount and Speed. The dice button changes the seed. The label's context menu provides component selection and an **Independent** option for varying motion between axes.

Added Motion and the main transition form one continuous curve. Added Motion settings apply to the selected property, even when its timing is linked to other properties.

## Linking and reset

Right-click a property label to open its context menu. **Link with** links the relevant keyframes across properties, creating a missing partner when needed. With neither property keyframed, linking creates both at the playhead. Linked keyframes share movement and incoming timing; their property values remain independently editable. The menu stays open so multiple properties can be linked quickly.

Matching gutter-icon colours identify members of the same linked group. Linking is per keyframe, not a global relationship between entire properties. Other keyframes remain independent.

**Reset Parameter** restores the property's default and removes its keyframes. Amount and Speed also provide reset menus. These changes can be undone in the host.

## Header settings

The settings cog contains **Explicit Keyframe Editing**, off by default. When enabled, changing a value does not create a keyframe automatically. An unkeyframed property remains editable; a single keyframe can be edited from anywhere. With multiple keyframes, edits target the next keyframe in the gap, the exact keyframe at the playhead, or the nearest endpoint outside the sequence.

The motion-blur button toggles motion blur. Right-click it for sample count and shutter angle. The default is 16 samples and a 180° shutter; a zero shutter produces a sharp frame. Control+Option+M toggles motion blur for the selected effect while its inspector is available. The menu shows the shortcut.

Motion blur averages transformed source samples over a backward shutter window. It affects Added Motion as well as transitions. Spatial Blur runs before the transform and remains compatible with motion blur. Preview blur is not automatically suppressed at keyframes: playback, stopped previews, and export cannot be reliably distinguished through the host callbacks used here.

## Development

Open `Keyframeless.xcworkspace` at the repository root, or build from that directory:

```sh
xcodebuild -workspace Keyframeless.xcworkspace -scheme MagicMove \
  -configuration Debug -derivedDataPath DerivedData/Keyframeless build
scripts/test-magicmove.sh
```

See [architecture](Architecture.md) for how the plugin works and [tests](Tests/README.md) for automated tests and checks to run in Motion/FCP.

## Motion template

Final Cut Pro reaches the effect through a Motion template, which also decides which controls the inspector shows and in what order. `Template/` holds the manifest, the artwork, and the generated `effect.moef`; `scripts/templates/effect.moef.in` holds the document skeleton shared by future plugins.

```sh
scripts/motion-template.py build             # regenerate Template/effect.moef
scripts/motion-template.py install           # this account: ~/Movies/Motion Templates.localized
sudo scripts/motion-template.py install --system   # every account, where the installer puts it
scripts/motion-template.py uninstall         # removes whichever copies exist
```

Both locations are read by Final Cut Pro and Motion, and a template in each shows the effect twice, so `install` reports when the other one is also populated.

The published controls are the ones registered with `kFxParameterFlag_CUSTOM_UI` and without `kFxParameterFlag_HIDDEN`, in the order `addParametersWithError:` registers them. Reordering the FCP inspector means moving a line in `Plugin+Parameters.m` and regenerating, never republishing parameters by hand in Motion. `MagicMove/Tests/ParameterExport.m` reports that registration to the generator.

The generator pins the document to Motion 6.2 (`ozml` 5.14), which is the format FCP 11 reads; a newer Motion writes 5.15 on save and drops that support. It keeps `Publish OSC` on, without which the host never instantiates the on-screen control, and writes no parameter values, so defaults come from `MMDefaults` alone. `scripts/test-magicmove.sh` fails if the committed template no longer matches the registered parameters.

Artwork is one file: `Template/thumbnail.png`, a 16:9 export of at least 640x360, with the working file that produced it kept beside it. `build` renders the 640x360 and 192x108 copies the installed template carries into `Template/Thumbnails/`, which is generated and not committed. A master of the wrong shape is rejected rather than squashed, since `sips` resizes to exact dimensions.

A generated template carries no parameter values and no editor state, which Motion writes but the host does not need. That was verified in Final Cut Pro 12.3 and Motion 6.3 on macOS 26.5.1: the effect appears under Effects > Keyframeless with its thumbnail, the inspector follows the registration order, poses start at their defaults, and the on-screen controls draw.

The template really is what drives both, checked by changing each one on its own in the same hosts. Listing Anchor first in `MMLanes` moved that row to the top of the FCP inspector, and clearing `Publish OSC` in the installed document alone stopped the on-screen controls from drawing while the control class stayed registered and rendering carried on. A published parameter set is bound when the effect is applied, so a template change needs a relaunch and a freshly applied effect to show up.

## Installing and removing a release

Releases ship inside the Keyframeless installer built by `scripts/build-pkg.sh`, which lists Magic Move as one of its choices: the application goes to `/Applications/Keyframeless`, the template to the system-wide Final Cut Pro templates folder. The installed application declares both locations in its `Info.plist` and is also the uninstaller. Opening it shows what is on disk and removes all of it, including the PlugInKit registration and, unless asked to keep them, the saved defaults, normally without asking for a password. See [distribution](../Distribution/README.md).

## Setting defaults

Right-click Duration or Easing and choose **Set Default** to use the current setting for new keyframes. Duration saves only the time, not Use Available Time. These preferences apply across effect instances; existing keyframes keep their settings.

Right-click Amount / Speed to save both values for the selected Added Motion type. Wave, Wiggle, and Handheld have separate defaults. Switching types on a keyframe restores its previous edits, including after saving and reopening the document.

**Restore Factory Default** clears that saved preference for future use. It does not reset the current animation. **Reset Parameter** applies the saved default to the current Duration, Easing, or Amount / Speed values, falling back to the factory value when no preference is saved. It leaves Use Available Time unchanged.
