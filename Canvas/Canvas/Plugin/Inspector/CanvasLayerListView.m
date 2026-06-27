/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerListView_Private.h"

#import "CanvasLayerRender.h"
#import "CanvasLayerRowViews.h"
#import "CanvasLayerTree.h"
#import "CanvasLocalized.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKCheckboxRowView.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKSVGParser.h>
#import <KeyframelessKit/KKShape.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

// Build-time helpers (implemented in the primary @implementation below).
@interface CanvasLayerListView ()
- (NSTextField *)_buildTitleLabel;
- (void)_buildAutoSelectRow;
- (void)_buildScrollWell;
- (void)_buildEmptyState;
- (NSStackView *)_buildHintRow;
- (void)_buildEdgeShadowsAndBorder;
- (void)_installConstraintsWithTitle:(NSTextField *)title
                                hint:(NSStackView *)hint;
@end

@implementation CanvasLayerListView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _selection = [NSMutableIndexSet indexSet];
    _editingIndex = -1;
    _hoveredRowIndex = -1;
    _paths = [NSMutableArray array];
    _rowViews = [NSMutableArray array];
    _collapsedGroups = [NSMutableSet set];
    _thumbCache = [NSMutableDictionary dictionary];
    _symConfig = [NSImageSymbolConfiguration
        configurationWithPointSize:KKSymbolPointSize
                            weight:NSFontWeightRegular];
    [self _build];
  }
  return self;
}

- (void)_build {
  NSTextField *title = [self _buildTitleLabel];
  [self _buildAutoSelectRow];
  [self _buildScrollWell];
  [self _buildEmptyState];
  NSStackView *hint = [self _buildHintRow];
  [self _buildEdgeShadowsAndBorder];
  [self _installConstraintsWithTitle:title hint:hint];

  NSClipView *clip = _scroll.contentView;
  clip.postsBoundsChangedNotifications = YES;
  [NSNotificationCenter.defaultCenter
      addObserver:self
         selector:@selector(_scrollBoundsChanged:)
             name:NSViewBoundsDidChangeNotification
           object:clip];
}

- (NSTextField *)_buildTitleLabel {
  NSTextField *title =
      [NSTextField labelWithString:CLoc(@"Layers", @"Layers panel title.")];
  title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  title.textColor = NSColor.secondaryLabelColor;
  title.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:title];
  return title;
}

// "Auto-select layers" toggle, sitting just under the title and above the well.
// Standard label-left / checkbox-right row (KKCheckboxRowView), like motion
// blur etc. Off by default; when on, clicking a layer in the viewer selects it.
// Images only for now (the OSC hit-test skips non-image layers).
- (void)_buildAutoSelectRow {
  __weak typeof(self) weakSelf = self;
  KKCheckboxRowView *row = [[KKCheckboxRowView alloc]
      initWithTitle:CLoc(@"Auto-select layers",
                         @"Companion-panel toggle: click a layer in the "
                         @"viewer to select it.")
            tooltip:CLoc(@"Click a layer in the viewer to select it.",
                         @"Tooltip for the Auto-select layers toggle.")
            binding:^BOOL {
              __strong typeof(weakSelf) s = weakSelf;
              return s ? s->_autoSelectState : NO;
            }
    disabledBinding:nil
           onToggle:^(BOOL on) {
             __strong typeof(weakSelf) s = weakSelf;
             if (!s)
               return;
             s->_autoSelectState = on;
             if (s.onAutoSelectToggled)
               s.onAutoSelectToggled(on);
           }];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:row];
  _autoSelectRow = row;
}

- (BOOL)autoSelect {
  return _autoSelectState;
}

- (void)setAutoSelect:(BOOL)autoSelect {
  _autoSelectState = autoSelect;
  [_autoSelectRow popoverDidRefresh]; // re-reads the binding into the checkbox
}

// The scrollable well: scroll view + flipped document view + the vertical rows
// stack. Sets _scroll and _rowsStack; the doc is reachable as the scroll's
// documentView.
- (void)_buildScrollWell {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.autohidesScrollers = YES;
  scroll.drawsBackground = YES;
  scroll.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.2];
  scroll.borderType = NSNoBorder;
  scroll.wantsLayer = YES;
  scroll.layer.cornerRadius = KKRadiusMD;
  scroll.layer.masksToBounds = YES;
  [self addSubview:scroll];
  _scroll = scroll;

  CanvasLayerDocView *doc =
      [[CanvasLayerDocView alloc] initWithFrame:NSZeroRect];
  doc.owner = self;
  doc.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.documentView = doc;

  NSStackView *rows = [[NSStackView alloc] initWithFrame:NSZeroRect];
  rows.orientation = NSUserInterfaceLayoutOrientationVertical;
  rows.alignment = NSLayoutAttributeLeading;
  rows.spacing = 1.0;
  rows.translatesAutoresizingMaskIntoConstraints = NO;
  [doc addSubview:rows];
  _rowsStack = rows;
}

// Centered "No shapes" placeholder shown when the stack is empty.
- (void)_buildEmptyState {
  NSImageView *icon = [NSImageView
      imageViewWithImage:
          [NSImage imageWithSystemSymbolName:@"square.3.layers.3d.slash"
                    accessibilityDescription:nil]];
  icon.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  [icon.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [icon.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;

  NSTextField *empty = [NSTextField
      labelWithString:CLoc(@"No shapes", @"Layers panel empty state.")];
  empty.font = [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightMedium];
  empty.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];

  NSStackView *emptyStack = [NSStackView stackViewWithViews:@[ icon, empty ]];
  emptyStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  emptyStack.spacing = KKSpacingSM;
  emptyStack.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:emptyStack];
  _emptyStack = emptyStack;
}

// "Drag images here" hint under the list. The label wraps (low compression
// resistance + hugging) so it yields to the panel width instead of widening it.
- (NSStackView *)_buildHintRow {
  NSImageView *hintIcon = [NSImageView
      imageViewWithImage:[NSImage imageWithSystemSymbolName:@"photo.fill"
                                   accessibilityDescription:nil]];
  hintIcon.contentTintColor = NSColor.secondaryLabelColor;
  [hintIcon.widthAnchor constraintEqualToConstant:KKFontSizeSM].active = YES;
  [hintIcon.heightAnchor constraintEqualToConstant:KKFontSizeSM].active = YES;
  NSTextField *hintLabel = [NSTextField
      labelWithString:CLoc(@"Drag images here to add them as layers",
                           @"Layers panel hint text under the list.")];
  hintLabel.font = [NSFont systemFontOfSize:KKFontSizeSM - 1.0];
  hintLabel.textColor = NSColor.secondaryLabelColor;
  hintLabel.lineBreakMode = NSLineBreakByWordWrapping;
  hintLabel.maximumNumberOfLines = 0;
  hintLabel.cell.wraps = YES;
  [hintLabel
      setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                               forOrientation:
                                   NSLayoutConstraintOrientationHorizontal];
  [hintLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
  _hintLabel = hintLabel;
  NSStackView *hint = [NSStackView stackViewWithViews:@[ hintIcon, hintLabel ]];
  hint.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  hint.alignment = NSLayoutAttributeTop;
  hint.spacing = KKSpacingXS;
  hint.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:hint];
  return hint;
}

- (void)_buildEdgeShadowsAndBorder {
  // Scroll-edge shadows (over the well, click/scroll pass through).
  _topShadow = [self _edgeShadowAtTop:YES];
  _bottomShadow = [self _edgeShadowAtTop:NO];
  [self addSubview:_topShadow];
  [self addSubview:_bottomShadow];

  // 1pt separator-color hairline matching the timing inspector box. An overlay
  // (not the scroll's own layer) because NSScrollView's clip view draws over
  // its backing layer's border. Passthrough so it never eats clicks/scroll.
  _listBorder = [[CanvasLayerPassthroughView alloc] initWithFrame:NSZeroRect];
  _listBorder.translatesAutoresizingMaskIntoConstraints = NO;
  _listBorder.wantsLayer = YES;
  _listBorder.layer.cornerRadius = KKRadiusMD;
  _listBorder.layer.borderColor = NSColor.separatorColor.CGColor;
  _listBorder.layer.borderWidth = 1.0;
  [self addSubview:_listBorder];
}

- (void)_installConstraintsWithTitle:(NSTextField *)title
                                hint:(NSStackView *)hint {
  const CGFloat pad = KKPaddingMD; // match the popover content inset
  NSScrollView *scroll = _scroll;
  NSView *doc = scroll.documentView;
  NSView *rows = _rowsStack;
  NSClipView *clip = scroll.contentView;

  KKCheckboxRowView *autoRow = _autoSelectRow;
  [NSLayoutConstraint activateConstraints:@[
    [title.topAnchor constraintEqualToAnchor:self.topAnchor constant:pad],
    [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:pad],

    [autoRow.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                      constant:KKSpacingXS],
    [autoRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:pad],
    [autoRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-pad],

    [scroll.topAnchor constraintEqualToAnchor:autoRow.bottomAnchor
                                     constant:KKSpacingSM],
    [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:pad],
    [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                          constant:-pad],
    [scroll.bottomAnchor constraintEqualToAnchor:hint.topAnchor
                                        constant:-KKSpacingSM],

    [hint.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                       constant:pad + KKPaddingSM],
    [hint.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                        constant:-pad],
    [hint.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-pad],

    [_topShadow.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [_topShadow.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [_topShadow.topAnchor constraintEqualToAnchor:scroll.topAnchor],
    [_topShadow.heightAnchor constraintEqualToConstant:kEdgeShadowHeight],
    [_bottomShadow.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [_bottomShadow.trailingAnchor
        constraintEqualToAnchor:scroll.trailingAnchor],
    [_bottomShadow.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [_bottomShadow.heightAnchor constraintEqualToConstant:kEdgeShadowHeight],

    [_listBorder.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [_listBorder.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [_listBorder.topAnchor constraintEqualToAnchor:scroll.topAnchor],
    [_listBorder.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],

    // The document view must itself be constrained (track the clip width + top,
    // size its height to the rows) - otherwise it has a zero frame and clicks
    // fall through to the clip view even though the rows draw.
    [doc.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [doc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [doc.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    // Contain the rows, and fill at least the viewport - so a file dropped
    // anywhere in the well (even a short list) lands on the doc and shows the
    // drop line.
    [doc.bottomAnchor constraintGreaterThanOrEqualToAnchor:rows.bottomAnchor],
    [doc.heightAnchor constraintGreaterThanOrEqualToAnchor:clip.heightAnchor],
    [rows.topAnchor constraintEqualToAnchor:doc.topAnchor],
    [rows.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
    [rows.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],

    [_emptyStack.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
    [_emptyStack.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor],
  ]];

  // When the rows exceed the viewport, the doc should hug them (so it scrolls);
  // the >= viewport constraint above only kicks in for a short list.
  NSLayoutConstraint *hug =
      [doc.bottomAnchor constraintEqualToAnchor:rows.bottomAnchor];
  hug.priority = NSLayoutPriorityDefaultLow;
  hug.active = YES;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (_keyMonitor)
    [NSEvent removeMonitor:_keyMonitor];
  if (_hoverMonitorLocal)
    [NSEvent removeMonitor:_hoverMonitorLocal];
  if (_hoverMonitorGlobal)
    [NSEvent removeMonitor:_hoverMonitorGlobal];
}

#pragma mark - Scroll-edge shadows

- (NSView *)_edgeShadowAtTop:(BOOL)atTop {
  CanvasLayerPassthroughView *v =
      [[CanvasLayerPassthroughView alloc] initWithFrame:NSZeroRect];
  v.translatesAutoresizingMaskIntoConstraints = NO;
  CAGradientLayer *grad = [CAGradientLayer layer];
  // Match Steno's ScrollShadowView: top max 0.15, bottom max 0.3.
  id dark = (id)[NSColor colorWithWhite:0.0 alpha:(atTop ? 0.15 : 0.3)].CGColor;
  id clear = (id)NSColor.clearColor.CGColor;
  // Layer coords are y-up: startPoint {0.5,1} = top edge.
  grad.colors = atTop ? @[ dark, clear ] : @[ clear, dark ];
  grad.startPoint = CGPointMake(0.5, 1.0);
  grad.endPoint = CGPointMake(0.5, 0.0);
  // Clip to the well's rounded corners (round only the matching edge's
  // corners).
  grad.cornerRadius = KKRadiusMD;
  grad.maskedCorners = atTop
                           ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner)
                           : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
  grad.masksToBounds = YES;
  v.layer = grad;
  v.wantsLayer = YES;
  v.alphaValue = 0.0; // driven by scroll position in _updateScrollShadows
  return v;
}

- (void)_scrollBoundsChanged:(NSNotification *)note {
  [self _updateScrollShadows];
}

- (void)_updateScrollShadows {
  NSClipView *clip = _scroll.contentView;
  CGFloat docH = _scroll.documentView.frame.size.height;
  CGFloat visH = clip.bounds.size.height;
  CGFloat scrollable = docH - visH;
  BOOL canScroll = scrollable > 0.5;
  CGFloat y =
      clip.bounds.origin.y; // flipped doc: 0 at top, grows scrolling down
  CGFloat pct = canScroll ? MAX(0.0, MIN(1.0, y / scrollable)) : 0.0;
  // Top fades in as you scroll down; bottom shows at the top and fades out as
  // you reach the bottom (matches Steno's ScrollShadowView).
  _topShadow.alphaValue = pct;
  _bottomShadow.alphaValue = canScroll ? (1.0 - pct) : 0.0;
}

- (void)layout {
  [super layout];
  // Wrapping NSTextField needs preferredMaxLayoutWidth = its laid-out width,
  // then a relayout, to compute the correct multi-line height.
  if (NSWidth(_hintLabel.frame) != _hintLabel.preferredMaxLayoutWidth) {
    _hintLabel.preferredMaxLayoutWidth = NSWidth(_hintLabel.frame);
    [super layout];
  }
  [self _updateScrollShadows];
}

- (void)setApiManager:(id<PROAPIAccessing>)apiManager {
  _apiManager = apiManager;
  _paths = [self _readPaths];
  [self _rebuildRows];
}

// Re-read the blob and rebuild. Called from the host's parameterChanged: so an
// undo/redo of kParamLayerData is reflected in the panel. (Our own edits also
// echo through here harmlessly - the data matches what we just wrote.)
- (void)highlightLayerID:(NSString *)layerID {
  NSUInteger idx = NSNotFound;
  for (NSUInteger i = 0; i < _paths.count; i++)
    if ([_paths[i].layerID isEqualToString:layerID]) {
      idx = i;
      break;
    }
  if (idx == NSNotFound && layerID.length)
    return; // unknown layer - leave the current highlight
  [_selection removeAllIndexes];
  if (idx != NSNotFound)
    [_selection addIndex:idx];
  [self _applySelectionStyling];
}

- (NSArray<NSString *> *)selectedLayerIDs {
  NSMutableArray<NSString *> *ids = [NSMutableArray array];
  [_selection enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    if (i < _paths.count && _paths[i].layerID.length)
      [ids addObject:_paths[i].layerID];
  }];
  return ids;
}

- (void)setSelectionToLayerIDs:(NSArray<NSString *> *)layerIDs {
  NSSet<NSString *> *want = [NSSet setWithArray:(layerIDs ?: @[])];
  [_selection removeAllIndexes];
  for (NSUInteger i = 0; i < _paths.count; i++)
    if (_paths[i].layerID.length && [want containsObject:_paths[i].layerID])
      [_selection addIndex:i];
  [self _applySelectionStyling];
}

- (void)setNonSelectableLayerIDs:(NSSet<NSString *> *)layerIDs {
  NSSet<NSString *> *next = layerIDs.count ? [layerIDs copy] : nil;
  if (next == _nonSelectableLayerIDs ||
      [next isEqualToSet:_nonSelectableLayerIDs])
    return;
  _nonSelectableLayerIDs = next;
  [self _applySelectionStyling];
}

- (void)reloadFromParam {
  // Skip the echo of our own write (the host may not have committed it yet, so
  // re-reading here would wipe the just-made edit). Only external changes
  // (undo/redo) fall through to an actual refresh.
  if (_selfWritePending > 0) {
    _selfWritePending--;
    return;
  }
  [self _commitRenameIfEditing];
  // Remap the selection by layerID, not raw index: a structural change (path op,
  // group, reorder, undo) reshuffles the stack, so keeping the old indices would
  // re-highlight whatever now sits at those rows. Capture the selected IDs from
  // the OLD paths first, then re-select the SAME layers in the new stack.
  // Layers that no longer exist - e.g. the operands a boolean op consumed - drop
  // out, so the selection collapses to the surviving result instead of clinging
  // to a sibling at the freed index.
  NSArray<NSString *> *prevSelIDs = [self selectedLayerIDs];
  _paths = [self _readPaths];
  NSSet<NSString *> *want = [NSSet setWithArray:prevSelIDs];
  [_selection removeAllIndexes];
  for (NSUInteger i = 0; i < _paths.count; i++)
    if (_paths[i].layerID.length && [want containsObject:_paths[i].layerID])
      [_selection addIndex:i];
  [self _rebuildRows];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

// While the panel is on screen and key, intercept its key events: Delete
// removes the selection (consumed so it doesn't delete the clip in FCP), and
// Cmd-Z / Cmd-Shift-Z drive Final Cut's own undo/redo via FxCommandAPI (the
// panel is a separate key window, so the events otherwise never reach FCP -
// same mechanism the kit's detached windows use).
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window && !_keyMonitor) {
    __weak typeof(self) weak = self;
    _keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *e) {
                                       __strong typeof(weak) s = weak;
                                       if (!s || e.window != s.window ||
                                           s->_editingIndex >= 0)
                                         return e; // let the rename field type
                                       NSEventModifierFlags m =
                                           e.modifierFlags &
                                           NSEventModifierFlagDeviceIndependentFlagsMask;
                                       // Delete / Backspace / Forward-delete
                                       // remove the selection and are consumed
                                       // so they never reach FCP.
                                       if (e.keyCode == 51 ||
                                           e.keyCode == 117) {
                                         [s _deleteSelectedRows];
                                         return nil;
                                       }
                                       NSString *key =
                                           e.charactersIgnoringModifiers
                                               .lowercaseString;
                                       if ((m & NSEventModifierFlagCommand) &&
                                           [key isEqualToString:@"z"]) {
                                         [s _performHostCommand:
                                                 (m & NSEventModifierFlagShift)
                                                     ? kFxCommand_Redo
                                                     : kFxCommand_Undo];
                                         return nil;
                                       }
                                       if ((m & NSEventModifierFlagCommand) &&
                                           !(m & NSEventModifierFlagShift) &&
                                           [key isEqualToString:@"g"]) {
                                         [s groupSelectedRows];
                                         return nil;
                                       }
                                       return e;
                                     }];
  } else if (!self.window && _keyMonitor) {
    [NSEvent removeMonitor:_keyMonitor];
    _keyMonitor = nil;
  }
  if (self.window && !_hoverMonitorLocal) {
    __weak typeof(self) weak = self;
    _hoverMonitorLocal = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                     handler:^NSEvent *(NSEvent *e) {
                                       [weak _updateHoverFromMouse];
                                       return e;
                                     }];
    _hoverMonitorGlobal = [NSEvent
        addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                      handler:^(NSEvent *e) {
                                        [weak _updateHoverFromMouse];
                                      }];
  } else if (!self.window && _hoverMonitorLocal) {
    [NSEvent removeMonitor:_hoverMonitorLocal];
    [NSEvent removeMonitor:_hoverMonitorGlobal];
    _hoverMonitorLocal = nil;
    _hoverMonitorGlobal = nil;
    [self hoverRowAtIndex:-1]; // clear any stuck highlight when detached
    _hoveredRowIndex = -1;
  }
}

// Hover highlight (mini-viewer): hit-test the live row frames against the current
// pointer and report the row under it (or -1). Driven by mouse-moved monitors
// rather than tracking areas - see the ivar note. Dedup so onLayerHovered fires
// only on a real change, not every move.
- (void)_updateHoverFromMouse {
  if (!self.window) {
    if (_hoveredRowIndex != -1) {
      _hoveredRowIndex = -1;
      [self hoverRowAtIndex:-1];
    }
    return;
  }
  NSPoint screen = [NSEvent mouseLocation];
  NSPoint win = [self.window convertPointFromScreen:screen];
  NSInteger idx = -1;
  // Only inside the scrolled, visible list area - not the header / margins, and
  // not rows clipped out of view.
  if (_scroll) {
    NSRect clip = [_scroll convertRect:_scroll.contentView.bounds toView:nil];
    if (NSPointInRect(win, clip)) {
      for (NSView *v in _rowViews) {
        if (![v isKindOfClass:[CanvasLayerRow class]] || v.isHidden)
          continue;
        NSRect f = [v convertRect:v.bounds toView:nil];
        if (NSPointInRect(win, f)) {
          idx = ((CanvasLayerRow *)v).rowIndex;
          break;
        }
      }
    }
  }
  if (idx == _hoveredRowIndex)
    return;
  _hoveredRowIndex = idx;
  [self hoverRowAtIndex:idx];
}

// Trigger a host command (undo/redo) from the panel. Must run inside an action
// scope opened with the plugin (paramActionTarget), like the kit does.
- (void)_performHostCommand:(FxCommand)command {
  id<PROAPIAccessing> api = self.apiManager;
  id<FxCustomParameterActionAPI_v4> act =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!act)
    return;
  id target = self.paramActionTarget ?: self;
  [act startAction:target];
  id<FxCommandAPI_v2> cmd = [api apiForProtocol:@protocol(FxCommandAPI_v2)];
  [cmd performCommand:command error:nil];
  [act endAction:target];
}
- (void)_deleteSelectedRows {
  if (_selection.count == 0)
    return;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *expanded = [self->_selection mutableCopy];
    [self->_selection enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [expanded addIndexes:CanvasLayerDescendantIndices(idx, paths)];
    }];
    NSUInteger firstDeleted = expanded.firstIndex;
    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 if (idx < paths.count)
                                   [paths removeObjectAtIndex:idx];
                               }];
    // Leave nothing selected after a delete (the canvas empty-selection model:
    // Figma/Illustrator/AE-style), rather than picking a survivor row.
    (void)firstDeleted;
    [self->_selection removeAllIndexes];
  }];
  // Swap the inspector to the surviving layer (timeline, OSC set, reset-button
  // state, panel highlight) - see _notifyPrimaryLayerSelected.
  [self _notifyPrimaryLayerSelected];
}

@end
