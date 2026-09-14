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

## Setting defaults

Right-click Duration or Easing and choose **Set Default** to use the current setting for new keyframes. Duration saves only the time, not Use Available Time. These preferences apply across effect instances; existing keyframes keep their settings.

Right-click Amount / Speed to save both values for the selected Added Motion type. Wave, Wiggle, and Handheld have separate defaults. Switching types on a keyframe restores its previous edits, including after saving and reopening the document.

**Restore Factory Default** clears that saved preference for future use. It does not reset the current animation. **Reset Parameter** applies the saved default to the current Duration, Easing, or Amount / Speed values, falling back to the factory value when no preference is saved. It leaves Use Available Time unchanged.
