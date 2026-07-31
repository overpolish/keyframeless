/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageColorPanelController.h"

#import <KeyframelessKit/KKFloatingPanel.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKPaddedScrollView.h>
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

#import "MirageColorSurfaceProps.h"
#import "MirageLocalized.h"
#import "MirageScopeSampler.h"
#import "MirageSurfaceCircleView.h"
#import "MirageSurfaceResponse.h"
#import "Plugin_Private.h" // +shaderSourceFromTimeline:
#import "MirageColorPanelController_Internal.h"

static const CGFloat kPanelWidth = 320.0;
/// Tall enough that the readout's own height comes out of the panel rather than out
/// of the ring: the circle is sized by whatever the well has left over, so every
/// point the readout takes is a point off the diameter you are dragging in.
static const CGFloat kPanelHeight = 388.0;
static const CGFloat kHeaderHeight = 28.0;

/// Three rows of the readout, which covers most mappings without a scroll. More
/// than that scrolls rather than growing into the circle's room.
static const CGFloat kReadoutHeight = 56.0;

/// The gap between two circles inside the shared well. Wider than the well's own
/// inset so the pair reads as two circles in one surface rather than as two boxes
/// that happen to touch.
static const CGFloat kRingGap = KKPaddingLG;

/// One circle's height, taken from what a single-ring panel has left after the
/// header, the readout and the well's own inset.
static CGFloat MirageRingCircleHeight(void) {
  return kPanelHeight - kHeaderHeight - kReadoutHeight - 4.0 * KKPaddingSM;
}

/// The one well both circles live in. Declaring a second surface adds a circle to
/// the SAME container rather than a second container: the rings are two readings
/// of one frame, and two wells read as two panels stacked.
static CGFloat MirageWellHeightForRingCount(NSUInteger count) {
  if (count < 1)
    count = 1;
  return (CGFloat)count * MirageRingCircleHeight() + 2.0 * KKPaddingSM +
         (CGFloat)(count - 1) * kRingGap;
}

/// The panel grows by exactly one circle per declared surface, DOWNWARD from the
/// header. A second circle is the whole point of declaring a second surface, so it
/// gets the same diameter as the first rather than both being shrunk to fit a fixed
/// panel - which would make the pair worse than either alone.
static CGFloat MiragePanelHeightForRingCount(NSUInteger count) {
  return kHeaderHeight + KKPaddingSM + kReadoutHeight + KKPaddingSM +
         MirageWellHeightForRingCount(count);
}

/// Its own defaults field, and named for the panel rather than the plugin, so
/// adding a second floating panel later cannot inherit this one's position.
static NSString *const kPositionKey = @"mirage.gradingPanel.origin";

@implementation _MirageFirstMouseButton {
  BOOL _holding;
  id _holdMonitor;
  id _holdGlobalMonitor;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

// Press-and-hold, because "show me it without the effect" is a comparison you
// make WHILE looking - the release matters as much as the press, and an
// action-on-click button has no release to offer.
//
// The release is caught with monitors rather than -mouseUp:, for the same reason
// the colour circle's drag is: this panel never becomes key, so the up routinely
// arrives forwarded or global and the button's own tracking never sees it. A
// missed release would leave the preview stuck showing the ungraded frame.
- (void)mouseDown:(NSEvent *)event {
  if (!self.onHoldChanged) {
    [super mouseDown:event];
    return;
  }
  if (_holding)
    return;
  _holding = YES;
  self.onHoldChanged(YES);
  __weak _MirageFirstMouseButton *weak = self;
  _holdMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                   handler:^NSEvent *(NSEvent *e) {
                                     [weak _endHold];
                                     return e;
                                   }];
  _holdGlobalMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                             handler:^(NSEvent *e) {
                                               [weak _endHold];
                                             }];
}

- (void)_endHold {
  [self _removeHoldMonitors];
  if (!_holding)
    return;
  _holding = NO;
  if (self.onHoldChanged)
    self.onHoldChanged(NO);
}

- (void)_removeHoldMonitors {
  if (_holdMonitor) {
    [NSEvent removeMonitor:_holdMonitor];
    _holdMonitor = nil;
  }
  if (_holdGlobalMonitor) {
    [NSEvent removeMonitor:_holdGlobalMonitor];
    _holdGlobalMonitor = nil;
  }
}

- (void)dealloc {
  [self _removeHoldMonitors];
}
@end

@implementation MirageColorPanelController (Layout)

/// How many circles the panel is currently showing: what the source declares,
/// never more than there are views, and never fewer than one.
- (NSUInteger)_ringCount {
  NSUInteger declared = MAX((NSUInteger)1, _ringKinds.count);
  return _circles.count ? MIN(declared, _circles.count) : declared;
}

- (MirageColorSurfaceRing)_ringAtIndex:(NSUInteger)index {
  if (index >= _ringKinds.count)
    return MirageColorSurfaceRingPlain;
  return (MirageColorSurfaceRing)_ringKinds[index].integerValue;
}

/// The circle painting the hue wheel, or nil when the shader declares none.
///
/// The eyedropper and the memory-colour declarations both read a position on THIS
/// ring: a cast is a hue, and there is nowhere on a tonal ramp for one to be. So
/// they bind to the circle rather than to "the surface", which
/// stopped being a single thing the moment a shader could declare two.
- (MirageSurfaceCircleView *)_hueCircle {
  for (NSUInteger i = 0; i < [self _ringCount] && i < _circles.count; i++)
    if ([self _ringAtIndex:i] == MirageColorSurfaceRingHue)
      return _circles[i];
  return nil;
}

/// Every frame in the panel, in one place, from the declared rings.
///
/// Bottom-up, so declaration order reads top-down: the author decides which
/// circle is on top. The panel is resized here too, holding its TOP edge, so a
/// recompile that adds a ring grows the panel away from the header the user
/// grabbed rather than sliding the whole thing up the screen.
- (void)_applyPanelLayout {
  if (!_panel || !_body || !_circles.count)
    return;
  NSUInteger rings = [self _ringCount];
  CGFloat height = MiragePanelHeightForRingCount(rings);
  NSRect frame = _panel.frame;
  if (fabs(NSHeight(frame) - height) > 0.5) {
    CGFloat top = NSMaxY(frame);
    frame.size.height = height;
    frame.origin.y = top - height;
    [_panel setFrame:frame display:_panel.isVisible];
  }
  _body.frame = NSMakeRect(0.0, 0.0, kPanelWidth, height);
  _header.frame =
      NSMakeRect(0.0, height - kHeaderHeight, kPanelWidth, kHeaderHeight);

  CGFloat y = KKPaddingSM;
  _readoutScroll.frame = NSMakeRect(KKPaddingSM, y, kPanelWidth - 2 * KKPaddingSM,
                                    kReadoutHeight);
  CGFloat hintHeight = ceil(kReadoutFontSize * 1.4) * 2.0;
  _readoutHint.frame = NSMakeRect(
      KKPaddingSM + KKPaddingLG, y + (kReadoutHeight - hintHeight) * 0.5,
      kPanelWidth - 2 * KKPaddingSM - 2 * KKPaddingLG, hintHeight);
  y += kReadoutHeight + KKPaddingSM;

  _well.frame = NSMakeRect(KKPaddingSM, y, kPanelWidth - 2 * KKPaddingSM,
                           MirageWellHeightForRingCount(rings));

  CGFloat circleHeight = MirageRingCircleHeight();
  CGFloat circleWidth = NSWidth(_well.bounds) - 2 * KKPaddingSM;
  CGFloat circleY = KKPaddingSM;
  for (NSInteger i = (NSInteger)rings - 1; i >= 0; i--) {
    _circles[i].hidden = NO;
    _circles[i].frame =
        NSMakeRect(KKPaddingSM, circleY, circleWidth, circleHeight);
    circleY += circleHeight + kRingGap;
  }
  for (NSUInteger i = rings; i < _circles.count; i++)
    _circles[i].hidden = YES;
}

// Ring + axis labels come from the `#color-surface` line.
//
// Driven by the SOURCE changing rather than by the panel being shown: the
// directive is normally edited with the panel already open, so re-reading it only
// on present meant a recompile never changed the ring - and a panel opened under a
// previous shader kept that shader's ring entirely.
- (void)_applySurfaceSpecIfChanged:(NSString *)source {
  if (!source.length)
    return;
  if ([source isEqualToString:_lastSpecSource ?: @""])
    return;
  _lastSpecSource = [source copy];
  NSArray<NSNumber *> *rings = MirageColorSurfaceRingsForSource(source);
  // A source the grammar rejects is left showing what it showed before rather
  // than collapsing to nothing: the editor reports it, and a panel that emptied
  // itself mid-sentence would fight the typing that is about to fix it.
  if (rings.count && rings.count <= kMirageColorSurfaceMaxCount)
    _ringKinds = rings;
  [self _pushSurfaceSpec];
}

/// Hand the resolved rings to the circles. Split from the change check because
/// the spec is resolved BEFORE the panel is built - the height depends on it -
/// so the views have to be able to catch up once they exist.
- (void)_pushSurfaceSpec {
  if (!_circles.count)
    return;
  NSString *source = _lastSpecSource;
  for (NSUInteger i = 0; i < [self _ringCount] && i < _circles.count; i++) {
    _circles[i].ring = [self _ringAtIndex:i];
    _circles[i].xAxisLabels =
        MirageColorSurfaceAxisLabelsAtIndex(source, i, @"xaxis");
    _circles[i].yAxisLabels =
        MirageColorSurfaceAxisLabelsAtIndex(source, i, @"yaxis");
  }
  [self _applyPanelLayout];
}

/// Read the declared rings straight from the lanes view, for the paths that run
/// before the panel exists: its height is a function of how many there are, and
/// it has to be right on the FIRST show rather than snapping a frame later.
- (void)_resolveRingsFromLanes {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return;
  [self _applySurfaceSpecIfChanged:[MiragePlugin
                                       shaderSourceFromTimeline:timeline]];
}

/// A text button for the header strip, right-aligned and sized to its own title.
///
/// Laid out by `-_layoutHeaderButtons`, not here: the write picker's title comes
/// from whichever control the current shader points at it, so both widths change
/// whenever the source does.
/// An icon button for the header strip. The name is not drawn, but it is what
/// VoiceOver reads, so it stays localized rather than becoming a symbol name.
- (_MirageFirstMouseButton *)_headerIconButtonNamed:(NSString *)symbol
                                              label:(NSString *)label
                                             action:(SEL)action {
  _MirageFirstMouseButton *button = [self _headerButtonWithAction:action];
  button.image = [NSImage imageWithSystemSymbolName:symbol
                           accessibilityDescription:label];
  button.imagePosition = NSImageOnly;
  button.accessibilityLabel = label;
  return button;
}

- (_MirageFirstMouseButton *)_headerButtonWithAction:(SEL)action {
  _MirageFirstMouseButton *button =
      [_MirageFirstMouseButton buttonWithTitle:@"" target:self action:action];
  button.bezelStyle = NSBezelStyleAccessoryBarAction;
  button.bordered = NO;
  button.font = [NSFont systemFontOfSize:kReadoutFontSize];
  button.contentTintColor = NSColor.secondaryLabelColor;
  button.autoresizingMask = NSViewMinXMargin;
  return button;
}

/// Lay out the header strip: comparison icons follow the title on the LEFT, the
/// samplers stay right-aligned.
///
/// The split is by what the buttons mean, not by what they look like. Before and
/// Split are view controls - they change nothing about the grade and read the same
/// in every shader, so an icon carries them and they sit with the title. The
/// samplers write parameters and are named for the control they write, which
/// changes with the source, so they keep their text and the right edge.
///
/// Re-run on every title change, since a text button's width is its content and a
/// stale frame would leave the pair overlapping or adrift.
- (void)_layoutHeaderButtons {
  CGFloat height = 18.0;
  CGFloat y = (kHeaderHeight - height) * 0.5;
  CGFloat left = _titleRightEdge + KKPaddingMD;
  for (NSButton *button in @[ _beforeButton, _splitButton ]) {
    if (!button || button.hidden)
      continue;
    button.frame = NSMakeRect(left, y, height, height);
    left += height + KKPaddingXS;
  }
  CGFloat right = kPanelWidth - KKPaddingMD;
  for (NSButton *button in @[ _pickButton, _pickColorButton ]) {
    if (!button || button.hidden)
      continue;
    CGFloat width = ceil(button.attributedTitle.size.width) + KKPaddingSM;
    button.frame = NSMakeRect(right - width, y, width, height);
    right -= width + KKPaddingSM;
  }
  // Left of both, and square: it carries a glyph, so its width is its height
  // rather than its (empty) title.
  if (_pickSourceButton && !_pickSourceButton.hidden)
    _pickSourceButton.frame = NSMakeRect(right - height, y, height, height);
}

- (KKFloatingPanel *)_ensurePanel {
  if (_panel)
    return _panel;
  // Sized for the rings the source already declared, so the panel is right on
  // the FIRST show rather than snapping a frame later - the rings are resolved
  // before this runs for exactly that reason.
  CGFloat panelHeight = MiragePanelHeightForRingCount([self _ringCount]);
  KKFloatingPanel *panel = [[KKFloatingPanel alloc]
      initWithContentSize:NSMakeSize(kPanelWidth, panelHeight)
              positionKey:kPositionKey];

  NSView *body = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kPanelWidth,
                                                          panelHeight)];
  body.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _body = body;

  // A dedicated drag strip rather than dragging by the whole background: the
  // surfaces below it are about to become click-and-drag targets themselves, so
  // the grab area has to be unambiguous before any of them exist. No background
  // of its own - the title sits directly on the panel, matching the Shaders
  // browser - so the grab cursor is what advertises the region.
  KKPanelDragHandleView *header = [[KKPanelDragHandleView alloc]
      initWithFrame:NSMakeRect(0, panelHeight - kHeaderHeight, kPanelWidth,
                               kHeaderHeight)];
  header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  _header = header;

  // Same size, weight and colour as the Shaders browser title, and the same
  // leading inset, so the two panels read as one family.
  NSTextField *title = [NSTextField
      labelWithString:RLoc(@"Color", @"Title of the Mirage colour panel: the "
                                     @"wheel, its scope and the grey picker.")];
  title.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
  title.textColor = NSColor.secondaryLabelColor;
  NSSize titleSize = title.intrinsicContentSize;
  CGFloat titleHeight = ceil(titleSize.height);
  // Sized to the word, not the strip: the comparison icons sit immediately after
  // it, so the title's right edge is a layout anchor rather than free space.
  title.frame = NSMakeRect(KKPaddingMD + 2,
                           (kHeaderHeight - titleHeight) * 0.5,
                           ceil(titleSize.width), titleHeight);
  [header addSubview:title];
  _titleRightEdge = NSMaxX(title.frame);

  // Both pickers are TEXT, not dropper icons. Two droppers side by side were
  // indistinguishable and neither said what it did - and they do opposite things:
  // one takes a MEASUREMENT the ring draws, the other WRITES a control. An icon
  // cannot carry that difference, and the write picker's label changes with the
  // shader anyway, so there was never one glyph that would have been honest.
  //
  // They are NSControls, so the panel's drag hit-test hands them their own clicks
  // while the rest of the header strip still drags the window.
  NSButton *pick = [self _headerButtonWithAction:@selector(_showPickMenu:)];
  // Only meaningful on a hue ring: the cast cross it feeds is drawn there and
  // nowhere else, so on a light ring this button measured something the circle had
  // no way to show. It stayed visible and did nothing, which is worse than absent.
  pick.hidden = YES;
  [header addSubview:pick];
  _pickButton = pick;

  NSButton *pickColor =
      [self _headerButtonWithAction:@selector(_toggleColorPicking:)];
  pickColor.hidden = YES;
  [header addSubview:pickColor];
  _pickColorButton = pickColor;

  // An ICON here where its two neighbours are text, and sitting to their left, so
  // the pick row reads as one group without a third label the 320pt strip has no
  // room for. What it does is the same question the eyedropper answers, asked of
  // one handle instead of all of them, so it belongs beside it rather than with
  // the view controls.
  NSString *fromClip = RLoc(@"Set from clip",
                            @"Color panel button: arms a click in the preview "
                            @"that aims the selected handle's controls at the "
                            @"color clicked in the original footage.");
  NSButton *pickSource =
      [self _headerIconButtonNamed:@"eyedropper.halffull"
                             label:fromClip
                            action:@selector(_togglePickFromClip:)];
  pickSource.toolTip =
      RLoc(@"Click a color in the preview to aim the selected handle at it. The "
           @"color is read from the original clip, not from the graded result.",
           @"Tooltip for the Color panel's click-to-pick button, explaining that "
           @"the sampled color comes from the untouched footage.");
  pickSource.hidden = YES;
  [header addSubview:pickSource];
  _pickSourceButton = pickSource;

  // Before/after, in the same text treatment as the pickers. Both are pure
  // preview state - they change what the mini viewer DRAWS and nothing else, so
  // neither writes a parameter, costs an undo step, or can reach a render.
  __weak typeof(self) weakHeader = self;
  NSButton *split =
      [self _headerIconButtonNamed:@"rectangle.split.2x1"
                             label:RLoc(@"Split",
                                        @"Color panel button that splits the "
                                        @"preview: the graded frame on the "
                                        @"left, the original on the right.")
                            action:@selector(_toggleCompareSplit:)];
  split.toolTip =
      RLoc(@"Show the graded frame beside the original. Drag the divider in the "
           @"preview to move the split.",
           @"Tooltip for the Color panel's split-preview toggle.");
  split.hidden = YES;
  [header addSubview:split];
  _splitButton = split;

  _MirageFirstMouseButton *before =
      [self _headerIconButtonNamed:@"eye"
                             label:RLoc(@"Before",
                                        @"Color panel button held down to see "
                                        @"the frame without the effect "
                                        @"applied.")
                            action:NULL];
  before.toolTip = RLoc(@"Hold to see the frame without this effect.",
                        @"Tooltip for the Color panel's hold-to-bypass button.");
  before.hidden = YES;
  before.onHoldChanged = ^(BOOL held) {
    [weakHeader _setCompareBypass:held];
  };
  [header addSubview:before];
  _beforeButton = before;
  [body addSubview:header];

  // The readout of what the puck just changed, in the shared scroll container so it
  // gets the same edge-fade shadows as every other scrolled list. Scrolled rather
  // than truncated: a shader can map any number of controls, and the one that
  // scrolled off is exactly the one you wanted to check.
  _readoutStack = [NSStackView new];
  _readoutStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _readoutStack.alignment = NSLayoutAttributeLeading;
  _readoutStack.spacing = 2.0;
  _readoutStack.edgeInsets =
      NSEdgeInsetsMake(KKPaddingXS, KKPaddingSM, KKPaddingXS, KKPaddingSM);
  KKPaddedScrollView *readout =
      [[KKPaddedScrollView alloc] initWithDocumentView:_readoutStack padding:0];
  readout.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [body addSubview:readout];
  _readoutScroll = readout;

  // What the empty readout says, rather than an empty box. It names the gesture,
  // because the puck is the one control here that has to be discovered, and it says
  // that real parameters move - which is the thing about this panel worth knowing.
  NSTextField *hint = [NSTextField labelWithString:MirageReadoutPlaceholder()];
  hint.font = [NSFont systemFontOfSize:kReadoutFontSize];
  hint.textColor = NSColor.tertiaryLabelColor;
  hint.alignment = NSTextAlignmentCenter;
  hint.lineBreakMode = NSLineBreakByWordWrapping;
  hint.maximumNumberOfLines = 2;
  // Two lines' worth, centred in the readout's height: a label given the full box
  // draws its text against the top, which reads as misaligned rather than as an
  // empty state.
  hint.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [body addSubview:hint];
  _readoutHint = hint;

  // The same well the Shaders browser puts its cards in - same fill, border,
  // radius - so the two panels read as one component set. The rings live inside it
  // rather than floating on the panel background.
  //
  // ONE well for however many surfaces the shader declares: the rings are two
  // readings of the same frame, and a container each would read as two panels
  // stacked rather than as one surface set.
  NSView *well = [[NSView alloc] initWithFrame:NSZeroRect];
  well.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  well.wantsLayer = YES;
  well.layer.cornerRadius = KKRadiusMD;
  well.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.2].CGColor;
  well.layer.borderColor = NSColor.separatorColor.CGColor;
  well.layer.borderWidth = 1.0;
  well.layer.masksToBounds = YES;
  [body addSubview:well];
  _well = well;

  // One circle per surface the grammar allows, whether or not the current shader
  // asks for both: the extra one is hidden, and never having to build a view under
  // a live panel is what keeps a recompile from tearing down a latched drag.
  __weak typeof(self) weakSelf = self;
  NSMutableArray<MirageSurfaceCircleView *> *circles = [NSMutableArray array];
  for (NSUInteger i = 0; i < kMirageColorSurfaceMaxCount; i++) {
    MirageSurfaceCircleView *circle =
        [[MirageSurfaceCircleView alloc] initWithFrame:NSZeroRect];
    // Frames come from -_applyPanelLayout alone: two circles sharing a well cannot
    // both be autoresized to fill it.
    circle.autoresizingMask = NSViewNotSizable;
    circle.hidden = YES;
    NSUInteger ringIndex = i;
    circle.onDragBegan = ^(NSUInteger puckIndex) {
      [weakSelf _beginPuckDrag:puckIndex ring:ringIndex];
    };
    circle.onPuckMovedTo = ^(NSUInteger puckIndex, NSPoint position) {
      [weakSelf _applyPuckTo:position puck:puckIndex ring:ringIndex];
    };
    circle.onDragEnded = ^(NSUInteger puckIndex) {
      [weakSelf _endPuckDragReason:@"mouse-up"];
    };
    circle.onResetToCentre = ^(NSUInteger puckIndex) {
      [weakSelf _resetMappedControlsForPuck:puckIndex ring:ringIndex];
    };
    [well addSubview:circle];
    [circles addObject:circle];
  }
  _circles = circles;

  [panel setPanelContentView:body];
  panel.dragHandleView = header; // retained by the view hierarchy
  _panel = panel;
  [self _pushSurfaceSpec];
  return _panel;
}

@end
