# InspectorControls

Reusable AppKit inspector controls extracted from the host-validated MagicMove
Position and Scale rows. This is a local static Swift package. It depends only on
AppKit/CoreGraphics; it does not import FxPlug, MotionTiming, Mirage, or the legacy
Keyframeless libraries.

## Use from another plugin

Add the local `InspectorControls` package to the plugin project and link its
`InspectorControls` product into the target that hosts the custom views. Import
`InspectorControls` from Objective-C or Swift. A separate embedded framework is
not required.

```objc
@import InspectorControls;

NSArray *components = @[
  [[ICInspectorComponent alloc] initWithIdentifier:1 label:@"X"
      suffix:@"px" fractionDigits:0],
  [[ICInspectorComponent alloc] initWithIdentifier:2 label:@"Y"
      suffix:@"px" fractionDigits:0]
];
ICInspectorRow *row = [[ICInspectorRow alloc] initWithLabel:@"Position"
    components:components showsLink:NO];
row.onValueCommit = ^(ICValueTextField *field) {
  // field.tag identifies the component. Convert field.doubleValue from display
  // units and commit through this plugin's parameter API.
};
row.onScrubBegin = ^{ /* Begin the plugin's undo group. */ };
row.onScrubEnd = ^{ /* End the plugin's undo group. */ };
```

The library owns:

- Row layout, native-control gutter, labels, units, and optional chain button.
- Typography, colors, and FCP/Motion accent tokens.
- Numeric fields, formatting, click-to-edit, scrubbing and modifier keys.
- Return/Tab navigation, clipboard handling, and edit/drag lifecycle callbacks.

The consumer owns parameter registration, native keyframes, values, display-unit
conversion, bounds, undo, refresh scheduling, and persistence. Component identifiers
are opaque integers, carried in `field.tag`. Configure `field.scrubStep` and its
number formatter's minimum/maximum where appropriate. Formatting preserves the
underlying numeric precision.

Rows start blank and disabled. When a valid snapshot arrives, set field values and
enabled states, skipping refresh while `row.interacting` is true. The library does
not fetch or store host state. A link-button consumer supplies its accessibility
label/tooltip and handles `onLinkToggle`, including saved state and tint updates.
Use weak captures when a callback refers back to its owning adapter.

Set `row.keyposeLinked` when the host reports that the current keypose is linked.
The row draws a small host-accent link symbol in the left gutter; this indicator
is independent of the optional `showsLink` scale/proportional link button.

`ICValueTextField` and `ICInspectorTokens` can also be used independently of the
row. Numeric scrubbing respects the attached `NSNumberFormatter` minimum and
maximum before dispatching a value. Further travel at a bound sends no action;
reversing direction immediately changes the value without accumulated overshoot.
Layout supports a nonempty component array; the validated two-component rows
retain their exact spacing and numeric baseline offset. OSC controls are outside
this package's scope.

## Verification

```sh
swift build --package-path InspectorControls --scratch-path DerivedData/InspectorControls
InspectorControls/Tests/run.sh
scripts/test-magicmove.sh --cpu-only
```

Standalone tests compile the public API and production sources with AppKit and
CoreGraphics only, under AddressSanitizer/UndefinedBehaviorSanitizer. MagicMove's
integration tests verify the consumer's host writes, caches, units, linking, and
undo. Actual host event delivery and visual matching remain host-test checkpoints.

`ICInspectorRow.titleMenuProvider` supplies a context menu for the title label
only (right-click or Control-click). The consumer owns menu actions and host
behavior; numeric fields, axis decorations, and the native keyframe gutter keep
their existing interactions.

`ICMenuToggleView` presents an indented, checkmarked menu option that keeps the
menu open on mouse activation. The consumer owns the NSMenuItem action and
updates its state after each operation. Text starts at 28pt (the native 16pt
heading inset plus 12pt); it has no host or timing dependencies.

`ICInspectorRow.keyposeLinkColor` supplies an optional gutter-badge tint. The
consumer assigns group colours; nil falls back to the host accent. This does not
affect row selection, component colours, or the separate aspect-link button.
`ICInspectorTokens.linkGroupColors` provides the shared categorical palette.

`componentColorsVisible` controls axis decoration tint independently of row
selection. Consumers enable it for rows whose curves are displayed. Selection
continues to control the label and background; suffixes retain their neutral tint.
