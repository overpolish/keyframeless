# InspectorControls

AppKit controls styled for the Motion and Final Cut Pro inspectors. The package handles layout and interaction; the plugin supplies values and handles host APIs, saving, and undo.

## Using the controls

Add the local `InspectorControls` package to your project and link its product into the target that displays the views. It is a static library, so no separate framework needs to be embedded. You can use it from Objective-C or Swift.

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

Rows provide labels, units, numeric fields, an optional link button, and space for the host's keyframe buttons. Fields support click-to-edit, scrubbing, modifier keys, Return/Tab navigation, and clipboard actions. `ICValueTextField` and `ICInspectorTokens` can also be used without a row.

Component identifiers are integers passed through `field.tag`. Set `field.scrubStep` and the number formatter's limits to suit the parameter. Display formatting does not change the stored precision. Scrubbing stops at the limits; reversing direction changes the value immediately.

Rows start blank and disabled. Set values and enabled states after reading them from the host, and skip refreshes while `row.interacting` is true. The plugin handles parameter registration, keyframes, unit conversion, undo, and saving. Use weak references in callbacks that refer to the owning view or adapter.

## Selection and linking

Set `row.keyposeLinked` to show the link badge in the left gutter. This is separate from the proportional-scale button enabled by `showsLink`. The plugin supplies that button's tooltip and accessibility label and handles `onLinkToggle`.

`ICInspectorRow.keyposeLinkColor` sets the badge colour; nil uses the host accent. `ICInspectorTokens.linkGroupColors` provides a palette for linked groups.

Set `componentColorsVisible` when the graph displays the row's curves, including when another row is selected. This colours the axis labels. Selection controls the property label and background; unit suffixes keep their neutral colour.

## Menus and dropdowns

`ICInspectorRow.titleMenuProvider` supplies the menu for right-click or Control-click on the property label. The plugin handles its actions. Numeric fields, axis labels, and native keyframe buttons keep their own interactions.

`ICMenuTextField` offers the same menu hook for a standalone label through `menuProvider`.

`ICMenuToggleView` displays a checkmarked option that keeps its menu open when clicked. The plugin handles the `NSMenuItem` action and updates its state. Text starts at 28pt: the native 16pt heading inset plus 12pt.

`ICPopUpButton` is a borderless `NSPopUpButton` with right-aligned text and drawn chevrons. Use its standard item, selection, and target/action APIs. Align its trailing edge with the row's final unit label to line up with numeric fields. Disabled text and chevrons use the shared disabled colour.

## Layout

`ICInspectorLayoutValue` calculates value and suffix frames for vector and slider rows. Every component reserves the same suffix space, including degrees and empty suffixes. Three-axis rows allow for a signed three-digit value at the configured precision, then reduce gaps and label space when necessary. A fixed reference value keeps columns from shifting as values change.

Popup text accounts for the numeric field's text inset. Suffixes are drawn outside the view hierarchy so they do not intercept clicks on the host's keyframe buttons.

Slider rows reserve their value area separately from the track. Changing suffix spacing therefore does not move the track endpoint. The same track and thumb geometry is used for drawing and pointer-to-value conversion.

## Header

`ICInspectorHeader` accepts a logo, accessory buttons, and a `menuProvider` block for the settings cog. The plugin supplies the menu, button states, actions, and undo handling. Keep logo resources in the plugin bundle and use a weak reference to the header in the menu callback.

## Build and test

From the repository root:

```sh
swift build --package-path InspectorControls --scratch-path DerivedData/InspectorControls
InspectorControls/Tests/run.sh
scripts/test-magicmove.sh --cpu-only
```

Standalone tests compile the controls with AppKit and CoreGraphics under AddressSanitizer and UndefinedBehaviorSanitizer. MagicMove's tests cover host writes, caches, units, linking, and undo. Check event handling and visual alignment in Motion/FCP as well.
