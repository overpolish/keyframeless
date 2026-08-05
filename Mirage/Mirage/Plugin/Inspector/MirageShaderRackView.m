/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The strip the shader chain scrolls inside: the scrolling rail and its
// overflow fades.
//
// What one box CONTAINS is MirageShaderRackView+Boxes.m; the reorder drag is
// MirageShaderRackView+DragDrop.m.

#import "MirageShaderRackView_Internal.h"

#import "MirageLocalized.h"

#import <KeyframelessKit/KKListRowViews.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

const CGFloat kMirageRackBoxHeight = 28.0;
const CGFloat kMirageRackConnectorWidth = 18.0;
const CGFloat kMirageRackDragThreshold = 4.0;

// Width of the overflow fade at each edge, and the ink it fades from - both
// matched to KKPillBar, whose category nav sits directly below this strip.
static const CGFloat kMirageRackEdgeWidth = 16.0;
static const CGFloat kMirageRackEdgeAlpha = 0.3;

@implementation MirageShaderRackView

// Padded to the same KKPaddingMD the category pill nav below it is inset by,
// top and bottom alike. The strip is a band between two things that are
// already spaced away from it, so its own padding only has to keep the boxes
// off the edges. The popover sizes the accessory row off this, so it has to
// stay the height the strip actually lays out at.
+ (CGFloat)stripHeight {
  return kMirageRackBoxHeight + 2 * KKPaddingMD;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _entries = @[];
    _boxViews = [NSMutableArray array];
    _symConfig = [NSImageSymbolConfiguration
        configurationWithPointSize:KKIconSizeSM - 1.0
                            weight:NSFontWeightRegular];
    [self _buildStrip];
  }
  return self;
}

// The chain scrolls sideways inside the strip: the strip's height is fixed, so
// a rack longer than the popover is wide runs off the trailing edge and is
// scrolled to, never wrapped onto a second line.
- (void)_buildStrip {
  _doc = [[MirageRackDocView alloc] initWithFrame:NSZeroRect];
  _doc.owner = self;
  _doc.translatesAutoresizingMaskIntoConstraints = NO;

  _chain = [[NSStackView alloc] initWithFrame:NSZeroRect];
  _chain.translatesAutoresizingMaskIntoConstraints = NO;
  _chain.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _chain.alignment = NSLayoutAttributeCenterY;
  _chain.distribution = NSStackViewDistributionFill;
  _chain.spacing = KKSpacingSM;
  [_doc addSubview:_chain];

  _addButton =
      KKListIconButton(@"plus", _symConfig, self, @selector(addTapped:), 0,
                       NSColor.secondaryLabelColor);
  _addButton.toolTip =
      RLoc(@"Add Shader", @"Mirage rack: tooltip on the button that appends "
                          @"another shader to the chain.");

  _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _scroll.translatesAutoresizingMaskIntoConstraints = NO;
  _scroll.drawsBackground = NO;
  _scroll.hasVerticalScroller = NO;
  // Never a scroll bar: the edge fades ARE the overflow affordance, and a bar
  // laid over a 28pt row of boxes cuts across them. Autohiding is not enough -
  // it still flashes on every scroll. The legacy scroller style is what would
  // reserve a gutter out of the strip's fixed height budget, so the style is
  // pinned to overlay and the automatic content insets (which is the other
  // route a scroller inset arrives by) are turned off with it.
  _scroll.hasHorizontalScroller = NO;
  _scroll.autohidesScrollers = YES;
  _scroll.scrollerStyle = NSScrollerStyleOverlay;
  _scroll.automaticallyAdjustsContentInsets = NO;
  _scroll.verticalScrollElasticity = NSScrollElasticityNone;
  _scroll.documentView = _doc;
  _scroll.contentView.postsBoundsChangedNotifications = YES;
  // A slight rounding on the scrolling region, clipped so a box scrolling past
  // an end is cut by the same curve. One step BELOW the boxes' own KKRadiusMD:
  // the boxes are the shape the strip is made of, and a container corner at or
  // above theirs would read as a panel they sit in rather than as the softened
  // ends of a rail. Set on the scroll view, whose layer is what the clip view
  // and the document draw inside.
  _scroll.wantsLayer = YES;
  _scroll.layer.cornerRadius = KKRadiusSM;
  _scroll.layer.masksToBounds = YES;
  [self addSubview:_scroll];

  [self _buildEdgeShadows];

  // The scroller carries the horizontal inset, not the chain inside it - the
  // same arrangement KKPillBar has directly below, where the BAR is inset and
  // its fades sit at its own edges. Inset the chain instead and the fades
  // (which can only sit at the scroller's edges) would run to the popover's
  // edge while the pill nav's stop short of it.
  NSClipView *clip = _scroll.contentView;
  [NSLayoutConstraint activateConstraints:@[
    [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:KKPaddingMD],
    [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-KKPaddingMD],
    [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
    [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

    // The document is as tall as the visible strip (nothing scrolls
    // vertically) and at least as wide, so a short chain still fills the row
    // and drops can be aimed past the last box.
    [_doc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [_doc.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [_doc.heightAnchor constraintEqualToAnchor:clip.heightAnchor],
    [_doc.widthAnchor constraintGreaterThanOrEqualToAnchor:clip.widthAnchor],

    [_chain.leadingAnchor constraintEqualToAnchor:_doc.leadingAnchor],
    // The document is pushed WIDER by the chain, never the other way around:
    // an equal trailing pin would stretch the chain to the visible width and
    // Fill would hand the slack to the last box's name label.
    [_doc.trailingAnchor
        constraintGreaterThanOrEqualToAnchor:_chain.trailingAnchor],
    [_chain.centerYAnchor constraintEqualToAnchor:_doc.centerYAnchor],
  ]];
  [_chain setContentHuggingPriority:NSLayoutPriorityRequired - 1
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
}

- (void)applyEntries:(NSArray<MirageRackEntry *> *)entries
            selected:(NSString *)selectedEntryID
         previewMode:(MirageRackPreviewMode)previewMode
        previewEntry:(NSString *)previewEntryID
       nonSelectable:(NSSet<NSString *> *)nonSelectableEntryIDs
              reason:(NSString *)reason {
  _entries = [entries copy] ?: @[];
  _selectedEntryID = [selectedEntryID copy];
  _previewMode = previewMode;
  _previewEntryID = [previewEntryID copy];
  _nonSelectableEntryIDs = [nonSelectableEntryIDs copy];
  _nonSelectableReason = [reason copy];
  [self rebuildBoxes];
}

// The same overflow fade KKPillBar gives the category nav directly below this
// strip, on the same geometry: a hit-transparent gradient view per edge whose
// LAYER opacity (a layer-hosting view ignores alphaValue) tracks how much
// there is to scroll to on that side. Same width, same ink, so the two rows
// read as one scrolling region rather than two conventions stacked.
- (void)_buildEdgeShadows {
  id ink =
      (__bridge id)
          [[NSColor blackColor] colorWithAlphaComponent:kMirageRackEdgeAlpha]
              .CGColor;
  id clear = (__bridge id)[NSColor clearColor].CGColor;

  _leadingShadow = [[KKListPassthroughView alloc] initWithFrame:NSZeroRect];
  _leadingShadow.wantsLayer = YES;
  _leadingGrad = [CAGradientLayer layer];
  _leadingGrad.colors = @[ ink, clear ];
  _leadingGrad.startPoint = CGPointMake(0, 0.5);
  _leadingGrad.endPoint = CGPointMake(1, 0.5);
  _leadingGrad.opacity = 0.0;
  _leadingShadow.layer = _leadingGrad;
  [self addSubview:_leadingShadow];

  _trailingShadow = [[KKListPassthroughView alloc] initWithFrame:NSZeroRect];
  _trailingShadow.wantsLayer = YES;
  _trailingGrad = [CAGradientLayer layer];
  _trailingGrad.colors = @[ clear, ink ];
  _trailingGrad.startPoint = CGPointMake(0, 0.5);
  _trailingGrad.endPoint = CGPointMake(1, 0.5);
  _trailingGrad.opacity = 0.0;
  _trailingShadow.layer = _trailingGrad;
  [self addSubview:_trailingShadow];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(updateEdgeShadows)
             name:NSViewBoundsDidChangeNotification
           object:_scroll.contentView];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)layout {
  [super layout];
  // Framed by hand rather than constrained: the shadow views are layer-hosting
  // overlays, and the view frame setter is what syncs the gradient layer's
  // geometry (setting the layer's own frame would clobber it).
  // Over the SCROLLER, not the strip: the scroller is inset by KKPaddingMD, and
  // a fade drawn past that inset covers popover margin no box can ever occupy.
  CGFloat h = NSHeight(self.bounds);
  NSRect scrolled = _scroll.frame;
  _leadingShadow.frame =
      NSMakeRect(NSMinX(scrolled), 0, kMirageRackEdgeWidth, h);
  _trailingShadow.frame = NSMakeRect(NSMaxX(scrolled) - kMirageRackEdgeWidth, 0,
                                     kMirageRackEdgeWidth, h);
  [self updateEdgeShadows];
}

- (void)updateEdgeShadows {
  CGFloat docW = NSWidth(_doc.frame);
  CGFloat visW = _scroll.contentView.bounds.size.width;
  CGFloat offX = _scroll.contentView.bounds.origin.x;
  CGFloat scrollable = docW - visW;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (scrollable <= 0.5) {
    _leadingGrad.opacity = 0.0;
    _trailingGrad.opacity = 0.0;
  } else {
    _leadingGrad.opacity =
        (float)MAX(0.0, MIN(1.0, offX / kMirageRackEdgeWidth));
    _trailingGrad.opacity =
        (float)MAX(0.0, MIN(1.0, (scrollable - offX) / kMirageRackEdgeWidth));
  }
  [CATransaction commit];
}

@end
