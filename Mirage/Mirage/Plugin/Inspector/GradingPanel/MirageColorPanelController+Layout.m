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

#import "MirageColorPanelController_Internal.h"
#import "MirageColorSurfaceProps.h"
#import "MirageLocalized.h"
#import "MirageScopeSampler.h"
#import "MirageSurfaceCircleView.h"
#import "MirageSurfaceResponse.h"
#import "Plugin_Private.h" // +shaderSourceFromTimeline:

static const CGFloat kPanelWidth = 320.0;
/// Tall enough that the readout's own height comes out of the panel rather than
/// out of the ring: the circle is sized by whatever the well has left over, so
/// every point the readout takes is a point off the diameter you are dragging
/// in.
static const CGFloat kPanelHeight = 388.0;
static const CGFloat kHeaderHeight = 28.0;

/// Three rows of the readout, which covers most mappings without a scroll. More
/// than that scrolls rather than growing into the circle's room.
static const CGFloat kReadoutHeight = 56.0;

/// The gap between two circles inside the shared well. Wider than the well's
/// own inset so the pair reads as two circles in one surface rather than as two
/// boxes that happen to touch.
static const CGFloat kRingGap = KKPaddingLG;

/// One circle's height, taken from what a single-ring panel has left after the
/// header, the readout and the well's own inset.
static CGFloat MirageRingCircleHeight(void) {
  return kPanelHeight - kHeaderHeight - kReadoutHeight - 4.0 * KKPaddingSM;
}

/// The one well both circles live in. Declaring a second surface adds a circle
/// to the SAME container rather than a second container: the rings are two
/// readings of one frame, and two wells read as two panels stacked.
///
/// `rowHeight` is the in-well button row, zero when the shader gives it nothing
/// to show. It is ADDED rather than taken out of the circle: a wheel you drag
/// in is worth more than a constant panel height, and the row is the one part
/// of this panel whose presence is a property of the shader rather than of the
/// design.
static CGFloat MirageWellHeightForRingCount(NSUInteger count,
                                            CGFloat rowHeight) {
  if (count < 1)
    count = 1;
  return (CGFloat)count * MirageRingCircleHeight() + 2.0 * KKPaddingSM +
         (CGFloat)(count - 1) * kRingGap + rowHeight;
}

/// The panel grows by exactly one circle per declared surface, DOWNWARD from
/// the header. A second circle is the whole point of declaring a second
/// surface, so it gets the same diameter as the first rather than both being
/// shrunk to fit a fixed panel - which would make the pair worse than either
/// alone.
static CGFloat MiragePanelHeightForRingCount(NSUInteger count,
                                             CGFloat rowHeight) {
  return kHeaderHeight + KKPaddingSM + kReadoutHeight + KKPaddingSM +
         MirageWellHeightForRingCount(count, rowHeight);
}

/// Its own defaults field, and named for the panel rather than the plugin, so
/// adding a second floating panel later cannot inherit this one's position.
static NSString *const kPositionKey = @"mirage.gradingPanel.origin";

@interface MirageColorPanelBodyView : NSView {
  NSTrackingArea *_arrowCursorArea;
}
@end

@implementation MirageColorPanelBodyView

- (void)resetCursorRects {
  [super resetCursorRects];
  [self addCursorRect:self.bounds cursor:NSCursor.arrowCursor];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_arrowCursorArea)
    [self removeTrackingArea:_arrowCursorArea];
  _arrowCursorArea = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                   NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_arrowCursorArea];
}

- (void)mouseEntered:(NSEvent *)event {
  [NSCursor.arrowCursor set];
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
/// The eyedropper and the memory-colour declarations both read a position on
/// THIS ring: a cast is a hue, and there is nowhere on a tonal ramp for one to
/// be. So they bind to the circle rather than to "the surface", which stopped
/// being a single thing the moment a shader could declare two.
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
  CGFloat rowHeight = [self _wellRowHeight];
  CGFloat height = MiragePanelHeightForRingCount(rings, rowHeight);
  NSRect frame = _panel.frame;
  if (fabs(NSHeight(frame) - height) > 0.5) {
    CGFloat top = NSMaxY(frame);
    [_panel setContentSize:NSMakeSize(kPanelWidth, height)
          keepingTopEdgeAt:top];
    frame = _panel.frame;
  }
  _body.frame = NSMakeRect(0.0, 0.0, kPanelWidth, height);
  _header.frame =
      NSMakeRect(0.0, height - kHeaderHeight, kPanelWidth, kHeaderHeight);

  CGFloat y = KKPaddingSM;
  _readoutScroll.frame =
      NSMakeRect(KKPaddingSM, y, kPanelWidth - 2 * KKPaddingSM, kReadoutHeight);
  CGFloat hintHeight = ceil(kReadoutFontSize * 1.4) * 2.0;
  _readoutHint.frame = NSMakeRect(
      KKPaddingSM + KKPaddingLG, y + (kReadoutHeight - hintHeight) * 0.5,
      kPanelWidth - 2 * KKPaddingSM - 2 * KKPaddingLG, hintHeight);
  y += kReadoutHeight + KKPaddingSM;

  _well.frame = NSMakeRect(KKPaddingSM, y, kPanelWidth - 2 * KKPaddingSM,
                           MirageWellHeightForRingCount(rings, rowHeight));

  // The row belongs to the ring click-to-pick answers to, which is the same
  // ring the slot pair adds a handle to. With two circles stacked that is not
  // necessarily the top one, so it is asked for rather than assumed.
  NSUInteger rowRing = MIN([self _pickRingIndex], rings - 1);
  CGFloat circleHeight = MirageRingCircleHeight();
  CGFloat circleWidth = NSWidth(_well.bounds) - 2 * KKPaddingSM;
  CGFloat circleY = KKPaddingSM;
  for (NSInteger i = (NSInteger)rings - 1; i >= 0; i--) {
    _circles[i].hidden = NO;
    _circles[i].frame =
        NSMakeRect(KKPaddingSM, circleY, circleWidth, circleHeight);
    circleY += circleHeight;
    if (rowHeight > 0.0 && (NSUInteger)i == rowRing) {
      [self _layoutWellRowInRect:NSMakeRect(KKPaddingSM, circleY, circleWidth,
                                            rowHeight)];
      circleY += rowHeight;
    }
    circleY += kRingGap;
  }
  for (NSUInteger i = rings; i < _circles.count; i++)
    _circles[i].hidden = YES;
}

// Ring + axis labels come from the `#color-surface` line.
//
// Driven by the SOURCE changing rather than by the panel being shown: the
// directive is normally edited with the panel already open, so re-reading it
// only on present meant a recompile never changed the ring - and a panel opened
// under a previous shader kept that shader's ring entirely.
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
  [self _applySurfaceSpecIfChanged:[self _entrySource:timeline]];
}

/// A panel button in the shared chrome style, right-aligned within its strip.
/// Pass a nil `symbol` for the text buttons, whose title is set by the caller.
///
/// Laid out by `-_layoutHeaderButtons`, not here: the write picker's title
/// comes from whichever control the current shader points at it, so both widths
/// change whenever the source does.
- (_MirageFirstMouseButton *)_iconButtonNamed:(NSString *)symbol
                                        label:(NSString *)label
                                       action:(SEL)action {
  _MirageFirstMouseButton *button =
      MirageMakeIconButton(symbol, label, self, action);
  button.autoresizingMask = NSViewMinXMargin;
  return button;
}

- (_MirageFirstMouseButton *)_headerButtonWithAction:(SEL)action {
  return [self _iconButtonNamed:nil label:nil action:action];
}

/// Lay out the header strip: the samplers, right-aligned.
///
/// They write parameters and are named for the control they write, which
/// changes with the source, so they keep their text and the right edge.
///
/// Nothing else is here. The three buttons that act on ONE HANDLE moved into
/// the well, above the ring they aim at (`-_layoutWellRowInRect:`), and the
/// three that act on the PREVIEW moved onto the preview itself - Before, Split
/// and Show Selection belong to the mini viewer every template has, not to the
/// panel only a `#color-surface` one gets.
///
/// Re-run on every title change, since a text button's width is its content and
/// a stale frame would leave the pair overlapping or adrift.
- (void)_layoutHeaderButtons {
  CGFloat height = 18.0;
  CGFloat y = (kHeaderHeight - height) * 0.5;
  CGFloat right = kPanelWidth - KKPaddingMD;
  for (NSButton *button in @[ _pickButton, _pickColorButton ]) {
    if (!button || button.hidden)
      continue;
    CGFloat width = ceil(button.attributedTitle.size.width) + KKPaddingSM;
    button.frame = NSMakeRect(right - width, y, width, height);
    right -= width + KKPaddingSM;
  }
}

- (KKFloatingPanel *)_ensurePanel {
  if (_panel)
    return _panel;
  // Sized for the rings the source already declared, so the panel is right on
  // the FIRST show rather than snapping a frame later - the rings are resolved
  // before this runs for exactly that reason.
  CGFloat panelHeight =
      MiragePanelHeightForRingCount([self _ringCount], [self _wellRowHeight]);
  KKFloatingPanel *panel = [[KKFloatingPanel alloc]
      initWithContentSize:NSMakeSize(kPanelWidth, panelHeight)
              positionKey:kPositionKey];

  NSView *body = [[MirageColorPanelBodyView alloc]
      initWithFrame:NSMakeRect(0, 0, kPanelWidth, panelHeight)];
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
  title.frame = NSMakeRect(KKPaddingMD + 2, (kHeaderHeight - titleHeight) * 0.5,
                           ceil(titleSize.width), titleHeight);
  [header addSubview:title];

  // Both pickers are TEXT, not dropper icons. Two droppers side by side were
  // indistinguishable and neither said what it did - and they do opposite
  // things: one takes a MEASUREMENT the ring draws, the other WRITES a control.
  // An icon cannot carry that difference, and the write picker's label changes
  // with the shader anyway, so there was never one glyph that would have been
  // honest.
  //
  // They are NSControls, so the panel's drag hit-test hands them their own
  // clicks while the rest of the header strip still drags the window.
  NSButton *pick = [self _headerButtonWithAction:@selector(_showPickMenu:)];
  // Only meaningful on a hue ring: the cast cross it feeds is drawn there and
  // nowhere else, so on a light ring this button measured something the circle
  // had no way to show. It stayed visible and did nothing, which is worse than
  // absent.
  pick.hidden = YES;
  [header addSubview:pick];
  _pickButton = pick;

  NSButton *pickColor =
      [self _headerButtonWithAction:@selector(_toggleColorPicking:)];
  pickColor.hidden = YES;
  [header addSubview:pickColor];
  _pickColorButton = pickColor;

  [body addSubview:header];

  // The readout of what the puck just changed, in the shared scroll container
  // so it gets the same edge-fade shadows as every other scrolled list.
  // Scrolled rather than truncated: a shader can map any number of controls,
  // and the one that scrolled off is exactly the one you wanted to check.
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

  // What the empty readout says, rather than an empty box. It names the
  // gesture, because the puck is the one control here that has to be
  // discovered, and it says that real parameters move - which is the thing
  // about this panel worth knowing.
  NSTextField *hint = [NSTextField labelWithString:MirageReadoutPlaceholder()];
  hint.font = [NSFont systemFontOfSize:kReadoutFontSize];
  hint.textColor = NSColor.tertiaryLabelColor;
  hint.alignment = NSTextAlignmentCenter;
  hint.lineBreakMode = NSLineBreakByWordWrapping;
  hint.maximumNumberOfLines = 2;
  // Two lines' worth, centred in the readout's height: a label given the full
  // box draws its text against the top, which reads as misaligned rather than
  // as an empty state.
  hint.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [body addSubview:hint];
  _readoutHint = hint;

  // The same well the Shaders browser puts its cards in - same fill, border,
  // radius - so the two panels read as one component set. The rings live inside
  // it rather than floating on the panel background.
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

  [self _buildWellRowInWell:well];

  // One circle per surface the grammar allows, whether or not the current
  // shader asks for both: the extra one is hidden, and never having to build a
  // view under a live panel is what keeps a recompile from tearing down a
  // latched drag.
  __weak typeof(self) weakSelf = self;
  NSMutableArray<MirageSurfaceCircleView *> *circles = [NSMutableArray array];
  for (NSUInteger i = 0; i < kMirageColorSurfaceMaxCount; i++) {
    MirageSurfaceCircleView *circle =
        [[MirageSurfaceCircleView alloc] initWithFrame:NSZeroRect];
    // Frames come from -_applyPanelLayout alone: two circles sharing a well
    // cannot both be autoresized to fill it.
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
