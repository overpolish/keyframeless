/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeEditorView.h"
#import "KKGLSLSyntax.h" // KKExprCatalog for the function reference menu
#import "KKLaneCategoryNav.h"
#import "KKLinkBus.h"
#import "KKLinkExpr.h"
#import "KKLocalized.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView.h"
#import "KKPaddedScrollView.h"
#import "KKPaletteGenerator.h"
#import "KKPillToggleRowView.h"
#import "KKPopoverHeaderView.h"
#import "KKSliderView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h>

// Height of the category nav pill row (icon pills under the mini-viewer).
static const CGFloat kKKCategoryPillH = 24.0;

// A parameter-link expression editor sits as its own row directly under the
// value row whose lane carries an expression: 1 line collapsed, taller when
// expanded via the chevron button. The row reserves a bottom 16pt strip for the
// live result readout, so the ROW height = the text height + the strip; the
// gutter buttons centre on the TEXT height (kKKExprEditorTextH) = the first
// line.
static const CGFloat kKKExprEditorTextH = 30.0;
static const CGFloat kKKExprEditorRowH = 46.0;       // text + result strip
static const CGFloat kKKExprEditorExpandedH = 112.0; // ~3 lines + result strip

// A lane shows an inline expression editor when it carries a linkExpression AND
// is referenceable (not a code editor or a palette-generator bar - mirrors the
// manifest / row-label filter).
static BOOL KKLaneHasExpressionEditor(KKLane *lane) {
  // Present = the lane HAS an expression binding, even an empty one. Clearing
  // the editor text leaves an empty (passthrough) expression, and the editor
  // stays open; only "Remove Expression" (which nils linkExpression) closes it.
  return lane.linkExpression != nil && lane.valueType != KKLaneValueTypeCode &&
         !lane.paletteGeneratorBar;
}

// Vertical breathing room kept around the popover when its natural height is
// clamped to the screen (so the arrow + a small gap fit on a low-res display),
// and the floor below which we never clamp.
static const CGFloat kKKStaticPopoverScreenMargin = 48.0;
static const CGFloat kKKStaticPopoverMinHeight = 160.0;

// Global user preference (not per-clip): the mini-viewer size (0 = sm/default,
// 1 = md, 2 = lg) is a viewing aid, so it persists across sessions and clips
// like a UI setting, never in the timeline blob. Read by the width class method
// so every height calculation that derives from the width follows
// automatically.
static NSString *const kKKStaticPopoverSizeDefaultsKey =
    @"KKStaticPopoverMiniViewerSize";

@interface _KKStaticValuesPopoverView ()
+ (CGFloat)_heightForLanes:(NSArray<KKLane *> *)lanes
            descriptorPath:(nullable NSString *)descriptorPath
                clipAspect:(CGFloat)clipAspect
             reserveHeader:(BOOL)reserveHeader
          selectedCategory:(nullable NSString *)selectedCategory
             valuesByLabel:
                 (nullable NSDictionary<NSString *, NSArray<NSNumber *> *> *)
                     valuesByLabel;
@end

@implementation _KKStaticValuesPopoverView {
  NSMutableDictionary<NSString *, _KKStaticValueRow *> *_rowsByLabel;
  NSStackView *_stack;
  // Vertical scroller (top/bottom fade shadows) hosting only the param-row
  // stack, so the mini-viewer + header + category pill stay sticky above and a
  // small / low-resolution display can scroll the rows instead of clipping
  // them.
  KKPaddedScrollView *_rowsScroll;
  KKMiniViewerView *_miniViewer;
  // Header-band 3-segment pill (sm/md/lg) that sets the global mini-viewer
  // size; the mini-viewer's height constraint is updated in place so the
  // preview grows/shrinks without reopening the popover. Both nil with no
  // mini-viewer.
  KKPillToggleRowView *_sizePill;
  NSLayoutConstraint *_miniViewerHeightConstraint;
  KKPillToggleRowView *_renderModePill; // guide anchor; nil when no pill shown
  // Category nav: an icon pill row under the mini-viewer that filters which
  // param rows show. nil/empty when <2 distinct lane categories (no pill).
  KKPillToggleRowView *_categoryPill;
  NSArray<NSString *> *_categoryKeys; // ordered, first-seen
  NSString *_selectedCategory;        // currently shown category key
  NSDictionary<NSString *, NSString *> *_rowCategoryByLabel;
  // Live component values per lane (seeded from open-time keyposes, updated on
  // every edit) so conditional `visibleWhen` rules + the page-resize see the
  // current Mode/Type selections, not the stale open-time snapshot.
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_currentValuesByLabel;
  // YES when any lane carries a `visibleWhen` rule - gates the (cheap but not
  // free) per-edit visibility recompute to plugins that actually use it.
  BOOL _laneGatesVisibility;
  // YES while a colour swatch's shared panel is open. The presenter's outside-
  // click monitors read this (via -suppressesPopoverDismiss) and skip
  // dismissal, so clicking into the panel (a separate window) doesn't close the
  // popover.
  BOOL _colorPanelOpen;
  // Debounced persist for the async colour panel: while it's open, a continuous
  // drag fires a value callback every frame. Persisting each one stacks an undo
  // step per frame, and we can't hold a synchronous drag undo group open across
  // the panel's own event loop (that corrupts FCP's FFUIAction nesting). So we
  // preview live but defer the persist, coalescing a burst into ONE undoable
  // write when the drag settles (timer) or the panel closes.
  NSTimer *_colorPersistTimer;
  NSString *_colorPendingLabel;
  NSArray<NSNumber *> *_colorPendingValues;
  // Excluded ("Animate" placeholder) rows aren't in _rowsByLabel; track them so
  // the category filter can hide/show them too.
  NSMutableDictionary<NSString *, NSView *> *_excludedRowsByLabel;
  // Inline parameter-link expression editor ROWS, keyed by lane label. Each is
  // a full-width container (the arranged stack subview) holding an inset
  // KKCodeEditorView, sitting directly under the lane's value row; the category
  // filter hides it with its row.
  NSMutableDictionary<NSString *, NSView *> *_exprRowsByLabel;
  // Labels whose expression editor is EXPANDED (taller); survives row rebuilds
  // so the user's expand choice sticks. The row owns its height
  // (-setEditorRowHeight:), so the chevron just re-reads this set.
  NSMutableSet<NSString *> *_exprExpandedLabels;
  // The KKCodeEditorView inside each expression row, keyed by lane label, so
  // the reference-insert menu can drop a token into the right editor. Torn down
  // wherever `_exprRowsByLabel` is (they are created and removed together).
  NSMutableDictionary<NSString *, KKCodeEditorView *> *_exprEditorByLabel;
  // Repeating timer that refreshes the inline result strips (live value->result
  // readout) so time-based expressions update as the playhead / playback moves.
  NSTimer *_exprResultTimer;
  // Playhead-motion tracking for the keypose sparkline marker: last tick's
  // linkTimelineSec + whether it changed. Moving (scrub/playback) -> the dot
  // follows the playhead; settled -> it pings back to the keypose
  // (editFraction).
  double _lastMarkerLinkSec;
  BOOL _playheadMoving;
  // Discovered link sources (other clips' manifests), cached so the display<->
  // stored token transforms don't hit disk on every keystroke. Refreshed when
  // an editor is installed and each time the insert menu opens.
  NSArray<KKLinkManifest *> *_linkManifests;
  // Colour labels the user has pinned via the per-swatch lock toggle. Transient
  // (never persisted): a palette reroll skips these. Survives row rebuilds
  // because it lives on the long-lived popover, keyed by lane label.
  NSMutableSet<NSString *> *_lockedColorLabels;
  CGFloat _labelColumnWidth; // uniform across rows (widest localized name)
  NSArray<KKLane *> *_lanes; // last lanes laid out (for per-category resize)
  // The anchor the category pill (and, when there's no pill, the row stack)
  // pins below - the mini-viewer / header bottom. Captured in init so the pill
  // can be rebuilt in place when the lane set changes (a category empties out).
  NSLayoutYAxisAnchor *_categoryNavTopAnchor;
  CGFloat _categoryNavTopInset;
  NSLayoutConstraint *_stackTopConstraint;
  NSString *_descriptorPath;
  CGFloat _clipAspect;
  void (^_onHandleValue)(NSString *, NSArray<NSNumber *> *);
  void (^_onSmoothToggled)(NSString *, BOOL);
  void (^_onLinkToggled)(NSString *, BOOL);
  void (^_onSetLinkExpression)(NSString *, NSString *);
  void (^_onGradientTypeChanged)(NSString *, NSInteger);
  BOOL _editsKeypose;
  void (^_onDragBegin)(void);
  void (^_onDragEnd)(void);
  NSButton *_navPrevButton;
  NSButton *_navNextButton;
  NSButton *_closeButton;
  void (^_onNavigate)(NSInteger);
  KKPopoverHeaderView *_header;
  BOOL _hasHeader;
  // Stored so the in-place row rebuild (add/remove/navigate) can re-derive
  // rows without the popover reopening: provider feeds reset defaults,
  // message/onAnimate drive the "Animate" (addable) rows.
  NSArray<NSNumber *> * (^_defaultsProvider)(NSString *);
  NSString *_excludedMessage;
  void (^_onAnimate)(NSString *);
  // Set (Advanced only) → editable rows gain a leading "−" remove button
  // that calls this with the row's label; nil → no remove gutter (Basic /
  // constants). Stored so the in-place rebuild keeps the gutter.
  void (^_rowRemoveHandler)(NSString *);
  // Constants popover only → rows gain a leading curve-glyph button that
  // calls this with the row's label to flip the lane to animatable.
  void (^_rowAddToAnimatedHandler)(NSString *);
}

- (void)setRowRemoveHandler:(void (^)(NSString *label))handler {
  _rowRemoveHandler = [handler copy];
}

- (void)setRowAddToAnimatedHandler:(void (^)(NSString *label))handler {
  _rowAddToAnimatedHandler = [handler copy];
}

- (void)setHeaderTitle:(NSString *)title {
  _header.title = title;
}

- (void)setHeaderDetail:(NSString *)detail {
  _header.detail = detail;
}

- (void)setHeaderLinked:(BOOL)linked {
  [_header setTrailingSymbolName:linked ? @"link" : nil];
}

- (void)setNavPrevEnabled:(BOOL)prev nextEnabled:(BOOL)next {
  _navPrevButton.enabled = prev;
  _navNextButton.enabled = next;
}

- (KKMiniViewerView *)miniViewer {
  return _miniViewer;
}

// Drop the mini-viewer (an MTKView, multi-MB GPU textures/drawables) on popover
// close. With NSPopoverBehaviorApplicationDefined the backing _NSPopoverWindow
// can outlive the NSPopover object, stranding this content view and - via this
// strong ivar - the mini-viewer, leaking its GPU memory. The popover layer
// calls this on close: niling the ivar + dropping the scroll view's
// documentView (its other strong hold) lets the mini-viewer dealloc and free
// that memory even while the empty window shell lingers.
- (void)releaseMiniViewer {
  // The result strips lose their time source and the popover is closing; stop
  // the refresh timer so it doesn't keep firing on a stranded content view.
  [_exprResultTimer invalidate];
  _exprResultTimer = nil;
  _miniViewer.enclosingScrollView.documentView = nil;
  [_miniViewer removeFromSuperview];
  _miniViewer = nil;
}

- (void)reconfigureForEditsKeypose:(BOOL)editsKeypose
                         withLanes:(NSArray<KKLane *> *)lanes
                    excludedLabels:(NSArray<NSString *> *)excludedLabels
                       headerTitle:(NSString *)headerTitle
                      headerDetail:(NSString *)headerDetail
                        headerIcon:(NSImage *)headerIcon
                     onHandleValue:(void (^)(NSString *, NSArray<NSNumber *> *))
                                       onHandleValue
                       onDragBegin:(void (^)(void))onDragBegin
                         onDragEnd:(void (^)(void))onDragEnd
                        onNavigate:(void (^)(NSInteger))onNavigate {
  _editsKeypose = editsKeypose;
  _onHandleValue = [onHandleValue copy];
  _onDragBegin = [onDragBegin copy];
  _onDragEnd = [onDragEnd copy];
  _onNavigate = [onNavigate copy];

  // Re-point the PRESERVED mini viewer's drag callbacks at the new mode's
  // blocks (keypose-write vs constant-write). The instance - and its overlay's
  // working mouse tracking - is untouched; recreating it via close+reopen is
  // what froze/crashed, so every constants<->keypose switch happens in place.
  if (_miniViewer) {
    __weak typeof(self) weakSelf = self;
    _miniViewer.onHandleValue =
        ^(NSString *label, NSArray<NSNumber *> *values) {
          [weakSelf liveUpdateValues:values forLabel:label];
          if (onHandleValue)
            onHandleValue(label, values);
        };
    _miniViewer.onHandleDragBegin = onDragBegin;
    _miniViewer.onHandleDragEnd = onDragEnd;
  }

  // Add the keypose nav chevrons (keypose mode) or remove them (constants
  // mode), then rebuild the header pinned after them. Same band geometry as
  // -initWithLanes:; the mini-viewer sits below the band and is unaffected.
  CGFloat bandH = [_KKStaticValuesPopoverView _renderModePillHeaderHeight];
  CGFloat bandCenterOffset = KKPaddingMD + bandH / 2.0;
  // The close button is always present (built in init, leftmost); nav + header
  // follow it.
  NSLayoutXAxisAnchor *bandLead =
      _closeButton ? _closeButton.trailingAnchor : self.leadingAnchor;
  CGFloat bandLeadInset = _closeButton ? KKSpacingMD : KKPaddingMD;
  if (editsKeypose && onNavigate && !_navPrevButton) {
    _navPrevButton = [self _makeNavButton:@"chevron.left"
                                direction:-1
                               onNavigate:onNavigate];
    _navNextButton = [self _makeNavButton:@"chevron.right"
                                direction:1
                               onNavigate:onNavigate];
    [self addSubview:_navPrevButton];
    [self addSubview:_navNextButton];
    [NSLayoutConstraint activateConstraints:@[
      [_navPrevButton.leadingAnchor constraintEqualToAnchor:bandLead
                                                   constant:bandLeadInset],
      [_navPrevButton.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                                   constant:bandCenterOffset],
      [_navPrevButton.widthAnchor constraintEqualToConstant:bandH],
      [_navPrevButton.heightAnchor constraintEqualToConstant:bandH],
      [_navNextButton.leadingAnchor
          constraintEqualToAnchor:_navPrevButton.trailingAnchor
                         constant:KKPaddingSM],
      [_navNextButton.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                                   constant:bandCenterOffset],
      [_navNextButton.widthAnchor constraintEqualToConstant:bandH],
      [_navNextButton.heightAnchor constraintEqualToConstant:bandH],
    ]];
  } else if (!editsKeypose && _navPrevButton) {
    [_navPrevButton removeFromSuperview];
    [_navNextButton removeFromSuperview];
    _navPrevButton = nil;
    _navNextButton = nil;
  }
  if (_header) {
    [_header removeFromSuperview];
    _header = nil;
  }
  if (headerTitle.length > 0) {
    _header = [[KKPopoverHeaderView alloc] initWithTitle:headerTitle
                                                  detail:headerDetail
                                                    icon:headerIcon];
    [self addSubview:_header];
    NSLayoutXAxisAnchor *titleLead =
        _navNextButton ? _navNextButton.trailingAnchor : bandLead;
    CGFloat titleLeadInset = _navNextButton ? KKSpacingMD : bandLeadInset;
    [NSLayoutConstraint activateConstraints:@[
      [_header.leadingAnchor constraintEqualToAnchor:titleLead
                                            constant:titleLeadInset],
      [_header.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                            constant:bandCenterOffset],
    ]];
  }

  // Rebuild the rows in the new mode (mini-viewer + the band we just rebuilt
  // are untouched by this call).
  [self rebuildRowsWithLanes:lanes excludedLabels:excludedLabels];

  // The mode flip changes which OSC set the mini-viewer draws (keypose handles
  // vs the constant's). The delegate's boundary-editing state was already
  // updated by the caller, but the paused MTKView doesn't repaint on its own -
  // force a redraw + handle refresh so it isn't left showing the old mode's OSC
  // until the next click (same repaint the keypose->keypose in-place update
  // does).
  [_miniViewer setNeedsDisplay:YES];
  [_miniViewer setHandlesNeedDisplay];
}

- (NSRect)guideRenderModePillScreenRectForMode:(KKMiniViewerRenderMode)mode {
  // Pill segments are built Off/Filmstrip/Onion in order, so the segment index
  // equals the render-mode raw value.
  if (!_renderModePill)
    return NSZeroRect;
  return [_renderModePill guidePillScreenRectAtIndex:(NSInteger)mode];
}

- (void)setOnSmoothToggled:(void (^)(NSString *, BOOL))handler {
  _onSmoothToggled = [handler copy];
}

- (void)setOnLinkToggled:(void (^)(NSString *, BOOL))handler {
  _onLinkToggled = [handler copy];
}

- (void)setOnSetLinkExpression:(void (^)(NSString *, NSString *))handler {
  _onSetLinkExpression = [handler copy];
}

- (void)setOnGradientTypeChanged:(void (^)(NSString *, NSInteger))handler {
  _onGradientTypeChanged = [handler copy];
}

- (void)rebindLanes:(NSArray<KKLane *> *)lanes {
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *row = _rowsByLabel[lane.label];
    if (!row || lane.keyposes.count == 0)
      continue;
    [row applyValues:lane.keyposes.firstObject.values];
    if (lane.spatialCurvable)
      [row applySmooth:lane.keyposes.firstObject.spatialSmooth];
    if (lane.aspectLinkable)
      [row applyLink:lane.aspectLinked];
  }
}

+ (NSInteger)_popoverSizeIndex {
  NSInteger i = [[NSUserDefaults standardUserDefaults]
      integerForKey:kKKStaticPopoverSizeDefaultsKey];
  return i < 0 ? 0 : (i > 2 ? 2 : i);
}

+ (NSInteger)popoverSizeIndex {
  return [self _popoverSizeIndex];
}

+ (void)setPopoverSizeIndex:(NSInteger)sizeIndex {
  [[NSUserDefaults standardUserDefaults]
      setInteger:(sizeIndex < 0 ? 0 : (sizeIndex > 2 ? 2 : sizeIndex))
          forKey:kKKStaticPopoverSizeDefaultsKey];
}

- (NSRect)guideSizePillScreenRectForIndex:(NSInteger)index {
  if (!_sizePill)
    return NSZeroRect;
  return [_sizePill guidePillScreenRectAtIndex:index];
}

+ (CGFloat)_popoverWidthForDescriptor:(NSString *)descriptorPath {
  if (descriptorPath.length == 0)
    return kPopoverW; // constants-only (no mini-viewer): never resized
  switch ([self _popoverSizeIndex]) {
  case 1:
    return kCanvasPopoverWMedium;
  case 2:
    return kCanvasPopoverWLarge;
  default:
    return kCanvasPopoverW; // sm
  }
}

+ (CGFloat)_canvasHeightForAspect:(CGFloat)aspect width:(CGFloat)w {
  CGFloat a = aspect > 0 ? aspect : (16.0 / 9.0);
  return (w - 2 * KKPaddingMD) / a;
}

+ (CGFloat)_renderModePillHeaderHeight {
  return 22.0; // pill row + spacing handled by KKPaddingMD below
}

+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes
           descriptorPath:(NSString *)descriptorPath
               clipAspect:(CGFloat)clipAspect
            reserveHeader:(BOOL)reserveHeader {
  return [self heightForLanes:lanes
               descriptorPath:descriptorPath
                   clipAspect:clipAspect
                reserveHeader:reserveHeader
             selectedCategory:nil];
}

+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes
           descriptorPath:(NSString *)descriptorPath
               clipAspect:(CGFloat)clipAspect
            reserveHeader:(BOOL)reserveHeader
         selectedCategory:(NSString *)selectedCategory {
  return [self _heightForLanes:lanes
                descriptorPath:descriptorPath
                    clipAspect:clipAspect
                 reserveHeader:reserveHeader
              selectedCategory:selectedCategory
                 valuesByLabel:nil];
}

+ (CGFloat)_heightForLanes:(NSArray<KKLane *> *)lanes
            descriptorPath:(NSString *)descriptorPath
                clipAspect:(CGFloat)clipAspect
             reserveHeader:(BOOL)reserveHeader
          selectedCategory:(NSString *)selectedCategory
             valuesByLabel:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)
                               valuesByLabel {
  // Conditionally-hidden lanes (visibleWhen rule fails) contribute no row
  // height, so the page hugs only what is shown for the current Mode/Type.
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneLabels(lanes, valuesByLabel);
  // Wrapping pill rows (markers) grow per wrapped line, so the per-row height
  // is width-dependent: feed the popover width + label column to heightForLane.
  CGFloat cw = [self _popoverWidthForDescriptor:descriptorPath];
  CGFloat labelColumnWidth = [_KKStaticValueRow labelColumnWidthForLanes:lanes];
  CGFloat rows = 0;
  NSArray<NSArray<NSString *> *> *cats = KKOrderedLaneCategories(lanes);
  if (cats.count > 0) {
    // Size to the selected category page only (its rows + any uncategorised
    // rows that show on every page), plus the pill row itself - so the popover
    // hugs each page and switching pills resizes to fit. Default to the first
    // category when none is selected yet (initial open).
    NSString *sel =
        selectedCategory.length ? selectedCategory : cats.firstObject[0];
    CGFloat page = 0;
    for (KKLane *lane in lanes)
      if ([condVisible containsObject:lane.label] &&
          (lane.categoryKey.length == 0 ||
           [lane.categoryKey isEqualToString:sel])) {
        page += [_KKStaticValueRow heightForLane:lane
                                    contentWidth:cw
                                labelColumnWidth:labelColumnWidth];
        if (KKLaneHasExpressionEditor(lane))
          page += kKKExprEditorRowH;
      }
    rows = page + kKKCategoryPillH + KKPaddingMD;
  } else {
    for (KKLane *lane in lanes)
      if ([condVisible containsObject:lane.label]) {
        rows += [_KKStaticValueRow heightForLane:lane
                                    contentWidth:cw
                                labelColumnWidth:labelColumnWidth];
        if (KKLaneHasExpressionEditor(lane))
          rows += kKKExprEditorRowH;
      }
  }
  // No trailing bottom pad: the rows scroller is pinned flush to the popover's
  // bottom edge (so its fade shadow sits at the absolute bottom). The leading
  // KKPaddingMD is the top inset above the header/mini-viewer/pill chain.
  CGFloat h = KKPaddingMD + rows;
  if (descriptorPath.length > 0)
    h += [self _canvasHeightForAspect:clipAspect
                                width:[self _popoverWidthForDescriptor:
                                                descriptorPath]] +
         KKPaddingMD;
  // The header band (title + render-mode pill + nav chevrons) shares one row.
  if (reserveHeader)
    h += [self _renderModePillHeaderHeight] + KKPaddingMD;
  return h;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSButton *)_makeCloseButton {
  NSImage *img = [NSImage imageWithSystemSymbolName:@"xmark"
                           accessibilityDescription:nil];
  NSButton *b = [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                                   target:self
                                   action:@selector(_closeButtonClicked:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  // Fire on mouseDOWN, not mouseUp: after the popover's shared ViewBridge
  // window is closed+reopened, FCP forwards the mouseDown but not the matching
  // mouseUp, so a normal (mouseUp) button would highlight and never fire.
  // mouseDown is always delivered, so the close still works across a reopen.
  [b.cell sendActionOn:NSEventMaskLeftMouseDown];
  return b;
}

- (void)_closeButtonClicked:(id)sender {
  if (self.onCloseTapped)
    self.onCloseTapped();
}

- (NSButton *)_makeNavButton:(NSString *)symbolName
                   direction:(NSInteger)direction
                  onNavigate:(void (^)(NSInteger))onNavigate {
  NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                           accessibilityDescription:nil];
  NSButton *b = [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                                   target:self
                                   action:@selector(_navButtonClicked:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.tag = direction;
  // Stash the callback on the view itself; both buttons share the same
  // handler so the ivar is a single block.
  _onNavigate = [onNavigate copy];
  return b;
}

- (void)_navButtonClicked:(NSButton *)sender {
  if (_onNavigate)
    _onNavigate((NSInteger)sender.tag);
}

- (KKPillToggleRowView *)_makeRenderModePill:(KKMiniViewerRenderMode)mode
                               onModeChanged:
                                   (void (^)(KKMiniViewerRenderMode))cb {
  NSImage * (^sym)(NSString *) = ^NSImage *(NSString *name) {
    NSImage *img = [NSImage imageWithSystemSymbolName:name
                             accessibilityDescription:nil];
    return img ?: [[NSImage alloc] initWithSize:NSMakeSize(11, 11)];
  };
  KKPillToggleRowView *pill = [[KKPillToggleRowView alloc] initWithIcons:@[
    sym(@"minus.circle"), sym(@"film"), sym(@"square.stack")
  ]];
  pill.translatesAutoresizingMaskIntoConstraints = NO;
  pill.grouped = YES;
  pill.radioMode = YES;
  NSMutableArray<NSNumber *> *states = [NSMutableArray array];
  for (NSInteger i = 0; i < 3; i++)
    [states addObject:@(i == (NSInteger)mode)];
  pill.states = states;
  pill.onToggled = ^(NSInteger index, BOOL isOn) {
    if (!isOn || !cb)
      return;
    cb((KKMiniViewerRenderMode)index);
  };
  return pill;
}

// A grouped 3-segment radio pill (sm / md / lg) styled like the render-mode
// pill beside it; the icons grade from compact to expanded.
- (KKPillToggleRowView *)_makeSizePillSelected:(NSInteger)sel
                                 onSizeChanged:(void (^)(NSInteger))cb {
  NSImage * (^sym)(NSString *) = ^NSImage *(NSString *name) {
    NSImage *img = [NSImage imageWithSystemSymbolName:name
                             accessibilityDescription:nil];
    return img ?: [[NSImage alloc] initWithSize:NSMakeSize(11, 11)];
  };
  KKPillToggleRowView *pill = [[KKPillToggleRowView alloc] initWithIcons:@[
    sym(@"rectangle.arrowtriangle.2.inward"), sym(@"rectangle"),
    sym(@"rectangle.arrowtriangle.2.outward")
  ]];
  pill.translatesAutoresizingMaskIntoConstraints = NO;
  pill.grouped = YES;
  pill.radioMode = YES;
  NSMutableArray<NSNumber *> *states = [NSMutableArray array];
  for (NSInteger i = 0; i < 3; i++)
    [states addObject:@(i == sel)];
  pill.states = states;
  pill.onToggled = ^(NSInteger index, BOOL isOn) {
    if (!isOn || !cb)
      return;
    cb(index);
  };
  return pill;
}

// Persist the global size preference, grow/shrink the mini-viewer height
// constraint in place, then re-fit the popover (the width class method now
// reports the selected size's width, so the height calc follows). The pill
// repaints its own active segment.
- (void)_setSizeIndex:(NSInteger)idx {
  [[NSUserDefaults standardUserDefaults]
      setInteger:idx
          forKey:kKKStaticPopoverSizeDefaultsKey];
  CGFloat W =
      [_KKStaticValuesPopoverView _popoverWidthForDescriptor:_descriptorPath];
  _miniViewerHeightConstraint.constant =
      [_KKStaticValuesPopoverView _canvasHeightForAspect:_clipAspect width:W];
  // Wrapping pill rows (markers) don't rebuild on resize, so re-derive their
  // block width + row height for the new content width before refitting.
  for (NSString *label in _rowsByLabel)
    [_rowsByLabel[label] updateContentWidth:W];
  [self _resizePopoverToSelectedCategory];
  if (_onSizeChanged)
    _onSizeChanged(idx);
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
               descriptorPath:(NSString *)descriptorPath
                   clipAspect:(CGFloat)clipAspect
                  headerTitle:(NSString *)headerTitle
                 headerDetail:(NSString *)headerDetail
                   headerIcon:(NSImage *)headerIcon
               canvasDelegate:(id<KKMiniViewerDelegate>)canvasDelegate
                   renderMode:(KKMiniViewerRenderMode)renderMode
                onModeChanged:(void (^)(KKMiniViewerRenderMode))onModeChanged
                   onNavigate:(void (^)(NSInteger))onNavigate
                onHandleValue:(void (^)(NSString *,
                                        NSArray<NSNumber *> *))onHandleValue
                  onDragBegin:(void (^)(void))onDragBegin
                    onDragEnd:(void (^)(void))onDragEnd
                 editsKeypose:(BOOL)editsKeypose
              initialCategory:(NSString *)initialCategory {
  BOOL showPill = (onModeChanged != nil && descriptorPath.length > 0);
  BOOL hasHeader = showPill || headerTitle.length > 0;
  CGFloat W =
      [_KKStaticValuesPopoverView _popoverWidthForDescriptor:descriptorPath];
  // Resolve the starting category up front so the initial height is sized to it
  // (not always the first category) - otherwise reopening on a remembered tab
  // with more rows clips to the first row.
  NSString *initialSel = KKResolveLaneCategory(lanes, initialCategory);
  CGFloat h = [_KKStaticValuesPopoverView heightForLanes:lanes
                                          descriptorPath:descriptorPath
                                              clipAspect:clipAspect
                                           reserveHeader:hasHeader
                                        selectedCategory:initialSel];
  self = [super initWithFrame:NSMakeRect(0, 0, W, h)];
  if (!self)
    return nil;
  _hasHeader = hasHeader;
  _descriptorPath = [descriptorPath copy];
  _clipAspect = clipAspect;
  _rowsByLabel = [NSMutableDictionary dictionary];
  _excludedRowsByLabel = [NSMutableDictionary dictionary];
  _exprRowsByLabel = [NSMutableDictionary dictionary];
  _exprExpandedLabels = [NSMutableSet set];
  _exprEditorByLabel = [NSMutableDictionary dictionary];
  _editsKeypose = editsKeypose;
  _onHandleValue = [onHandleValue copy];
  _onDragBegin = [onDragBegin copy];
  _onDragEnd = [onDragEnd copy];

  NSLayoutYAxisAnchor *stackTopAnchor = self.topAnchor;
  CGFloat stackTopInset = KKPaddingMD;
  NSLayoutYAxisAnchor *canvasTopAnchor = self.topAnchor;
  CGFloat canvasTopInset = KKPaddingMD;

  // Header band (one row, shared): nav chevrons (leftmost, fixed position) →
  // title; render-mode pill trailing. Everything shares the band's
  // vertical centre.
  CGFloat bandH = [_KKStaticValuesPopoverView _renderModePillHeaderHeight];
  CGFloat bandCenterOffset = KKPaddingMD + bandH / 2.0;
  BOOL hasNav = (showPill && onNavigate != nil);
  BOOL hasBand = (showPill || headerTitle.length > 0);

  // Close (X) button, leftmost in the band - always present (both modes) so the
  // popover can be dismissed without relying on focus loss. Nav + header
  // follow.
  NSLayoutXAxisAnchor *bandLead = self.leadingAnchor;
  CGFloat bandLeadInset = KKPaddingMD;
  if (hasBand) {
    _closeButton = [self _makeCloseButton];
    [self addSubview:_closeButton];
    [NSLayoutConstraint activateConstraints:@[
      [_closeButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                 constant:KKPaddingMD],
      [_closeButton.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                                 constant:bandCenterOffset],
      [_closeButton.widthAnchor constraintEqualToConstant:bandH],
      [_closeButton.heightAnchor constraintEqualToConstant:bandH],
    ]];
    bandLead = _closeButton.trailingAnchor;
    bandLeadInset = KKSpacingMD;
  }

  NSLayoutXAxisAnchor *titleLead = bandLead;
  CGFloat titleLeadInset = bandLeadInset;
  if (hasNav) {
    _navPrevButton = [self _makeNavButton:@"chevron.left"
                                direction:-1
                               onNavigate:onNavigate];
    _navNextButton = [self _makeNavButton:@"chevron.right"
                                direction:1
                               onNavigate:onNavigate];
    [self addSubview:_navPrevButton];
    [self addSubview:_navNextButton];
    [NSLayoutConstraint activateConstraints:@[
      [_navPrevButton.leadingAnchor constraintEqualToAnchor:bandLead
                                                   constant:bandLeadInset],
      [_navPrevButton.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                                   constant:bandCenterOffset],
      [_navPrevButton.widthAnchor constraintEqualToConstant:bandH],
      [_navPrevButton.heightAnchor constraintEqualToConstant:bandH],
      [_navNextButton.leadingAnchor
          constraintEqualToAnchor:_navPrevButton.trailingAnchor
                         constant:KKPaddingSM],
      [_navNextButton.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                                   constant:bandCenterOffset],
      [_navNextButton.widthAnchor constraintEqualToConstant:bandH],
      [_navNextButton.heightAnchor constraintEqualToConstant:bandH],
    ]];
    titleLead = _navNextButton.trailingAnchor;
    titleLeadInset = KKSpacingMD;
  }

  if (headerTitle.length > 0) {
    _header = [[KKPopoverHeaderView alloc] initWithTitle:headerTitle
                                                  detail:headerDetail
                                                    icon:headerIcon];
    [self addSubview:_header];
    [NSLayoutConstraint activateConstraints:@[
      [_header.leadingAnchor constraintEqualToAnchor:titleLead
                                            constant:titleLeadInset],
      [_header.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                            constant:bandCenterOffset],
    ]];
  }

  // Size pill (sm/md/lg): trailing-most in the band whenever there's a
  // mini-viewer, sitting beside the render-mode pill as a second grouped pill.
  if (descriptorPath.length > 0) {
    __weak typeof(self) weakSelfSize = self;
    _sizePill = [self
        _makeSizePillSelected:[_KKStaticValuesPopoverView _popoverSizeIndex]
                onSizeChanged:^(NSInteger idx) {
                  [weakSelfSize _setSizeIndex:idx];
                }];
    [self addSubview:_sizePill];
    [NSLayoutConstraint activateConstraints:@[
      [_sizePill.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                               constant:-KKPaddingMD],
      [_sizePill.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                              constant:bandCenterOffset],
      [_sizePill.heightAnchor constraintEqualToConstant:bandH],
    ]];
  }

  if (showPill) {
    __weak typeof(self) weakSelfPill = self;
    void (^wrappedModeChanged)(KKMiniViewerRenderMode) =
        ^(KKMiniViewerRenderMode m) {
          __strong typeof(weakSelfPill) ss = weakSelfPill;
          ss->_miniViewer.renderMode = (NSInteger)m;
          if (onModeChanged)
            onModeChanged(m);
        };
    KKPillToggleRowView *pill = [self _makeRenderModePill:renderMode
                                            onModeChanged:wrappedModeChanged];
    _renderModePill = pill;
    [self addSubview:pill];
    // Sit to the left of the size pill (which is trailing-most when a
    // mini-viewer is present); fall back to the band's trailing edge otherwise.
    NSLayoutXAxisAnchor *pillTrail =
        _sizePill ? _sizePill.leadingAnchor : self.trailingAnchor;
    CGFloat pillTrailInset = _sizePill ? -KKSpacingMD : -KKPaddingMD;
    [NSLayoutConstraint activateConstraints:@[
      [pill.trailingAnchor constraintEqualToAnchor:pillTrail
                                          constant:pillTrailInset],
      [pill.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                         constant:bandCenterOffset],
      [pill.heightAnchor constraintEqualToConstant:bandH],
    ]];
  }

  if (hasBand) {
    canvasTopAnchor = self.topAnchor;
    canvasTopInset = KKPaddingMD + bandH + KKPaddingMD;
    stackTopAnchor = self.topAnchor;
    stackTopInset = KKPaddingMD + bandH + KKPaddingMD;
  }
  if (descriptorPath.length > 0) {
    _miniViewer = [[KKMiniViewerView alloc] initWithFrame:NSZeroRect];
    _miniViewer.sourceDescriptorPath = descriptorPath;
    _miniViewer.canvasDelegate = canvasDelegate;
    _miniViewer.renderMode = (NSInteger)renderMode;
    __weak typeof(self) weakSelf = self;
    _miniViewer.onHandleValue =
        ^(NSString *label, NSArray<NSNumber *> *values) {
          // Live UI every tick (cheap); persist stays coalesced downstream.
          [weakSelf liveUpdateValues:values forLabel:label];
          if (onHandleValue)
            onHandleValue(label, values);
        };
    _miniViewer.onHandleDragBegin = onDragBegin;
    _miniViewer.onHandleDragEnd = onDragEnd;
    __weak typeof(self) weakSelfRes = self;
    _miniViewer.onSourceResolved = ^{
      __strong typeof(weakSelfRes) s = weakSelfRes;
      // Media size now known → re-render pixel-scaled (crop) fields.
      for (_KKStaticValueRow *row in s->_rowsByLabel.allValues)
        [row refreshDisplay];
    };
    _miniViewer.clipAspect = clipAspect > 0 ? clipAspect : (16.0 / 9.0);
    // Scale OSC element sizes against the SMALLEST popover's canvas height for
    // this aspect, so they stay a constant screen size at md/lg - the preview
    // zooms in around them instead of the controls growing (matches the main
    // viewer). Aspect is fixed for the popover, so this never changes.
    _miniViewer.oscReferenceHeight =
        [_KKStaticValuesPopoverView _canvasHeightForAspect:clipAspect
                                                     width:kCanvasPopoverW];
    _miniViewer.translatesAutoresizingMaskIntoConstraints = NO;
    _miniViewer.wantsLayer = YES;
    _miniViewer.layer.cornerRadius = 4.0;
    _miniViewer.layer.masksToBounds = YES;

    // Host the canvas as the documentView of an NSScrollView - this is the
    // exact arrangement the old (working) KKStageSequencerView used to get
    // magnify/scroll events. The subclass blocks at-boundary overscroll from
    // propagating to FCP's inspector root scroll view.
    _KKMiniViewerScrollView *sv =
        [[_KKMiniViewerScrollView alloc] initWithFrame:NSZeroRect];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = NO;
    sv.hasHorizontalScroller = NO;
    // documentView is pinned to the clip view (no scrollable content); without
    // this, [super scrollWheel:] elastically bounces the whole canvas on
    // overscroll. We still call super first for momentum/phase coherence.
    sv.horizontalScrollElasticity = NSScrollElasticityNone;
    sv.verticalScrollElasticity = NSScrollElasticityNone;
    sv.documentView = _miniViewer;
    [self addSubview:sv];
    NSClipView *clip = sv.contentView;
    _miniViewerHeightConstraint = [sv.heightAnchor
        constraintEqualToConstant:[_KKStaticValuesPopoverView
                                      _canvasHeightForAspect:clipAspect
                                                       width:W]];
    [NSLayoutConstraint activateConstraints:@[
      [sv.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                       constant:KKPaddingMD],
      [sv.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                        constant:-KKPaddingMD],
      [sv.topAnchor constraintEqualToAnchor:canvasTopAnchor
                                   constant:canvasTopInset],
      _miniViewerHeightConstraint,
      [_miniViewer.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
      [_miniViewer.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
      [_miniViewer.topAnchor constraintEqualToAnchor:clip.topAnchor],
      [_miniViewer.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],
    ]];

    // The crop size readout is drawn inside the canvas at the crop's
    // bottom-right corner (see _KKMiniViewerOverlay), matching the OSC.
    stackTopAnchor = sv.bottomAnchor;
    stackTopInset = KKPaddingMD;
  }

  // Capture the anchor the category nav (or, when there's no pill, the row
  // stack) pins below - the mini-viewer / header bottom - so the nav can be
  // rebuilt in place when the lane set changes (e.g. a category empties out).
  _categoryNavTopAnchor = stackTopAnchor;
  _categoryNavTopInset = stackTopInset;
  _rowCategoryByLabel = KKLaneCategoryByLabel(lanes);

  _stack = [NSStackView stackViewWithViews:@[]];
  _stack.translatesAutoresizingMaskIntoConstraints = NO;
  _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _stack.spacing = 0;
  // Only the rows scroll: the mini-viewer + header + category pill stay sticky
  // above, the param-row stack lives in a vertical scroller (with top/bottom
  // fade shadows). The stack self-sizes (intrinsic height); the scroller's
  // flipped clip anchors the rows at top and absorbs any small-screen overflow.
  _rowsScroll = [[KKPaddedScrollView alloc] initWithDocumentView:_stack
                                                         padding:0];
  _rowsScroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_rowsScroll];
  [NSLayoutConstraint activateConstraints:@[
    [_rowsScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_rowsScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_rowsScroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
  ]];
  // Builds the category pill (when >1 category) and the rows scroller's top
  // constraint.
  [self _rebuildCategoryNavForLanes:lanes initialCategory:initialCategory];

  _lanes = [lanes copy];
  [self _seedCurrentValues];
  _labelColumnWidth = [_KKStaticValueRow labelColumnWidthForLanes:lanes];
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *row = [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
    [self _installExprEditorForLane:lane];
  }
  [self _applyCategoryFilter];
  return self;
}

// Build (or rebuild) the category pill + the row stack's top constraint for the
// current lanes. The pill shows only when the lanes split into >1 category;
// otherwise the stack pins straight to the nav top anchor (no pill).
// `requested` is the category to try to land on (the clicked keypose's /
// remembered tab on first build, or the current selection on a rebuild); it
// falls back to the first category. Lets the constants popover drop a tab live
// when its last constant lane is moved to animated, without reopening (no
// mini-viewer blink).
- (void)_rebuildCategoryNavForLanes:(NSArray<KKLane *> *)lanes
                    initialCategory:(NSString *)requested {
  [_categoryPill removeFromSuperview];
  _categoryPill = nil;
  _stackTopConstraint.active = NO;
  _stackTopConstraint = nil;

  NSLayoutYAxisAnchor *top = _categoryNavTopAnchor;
  CGFloat inset = _categoryNavTopInset;
  __weak typeof(self) weakSelfCat = self;
  KKPillToggleRowView *pill =
      KKMakeLaneCategoryPill(lanes, requested, ^(NSString *categoryKey) {
        __strong typeof(weakSelfCat) ss = weakSelfCat;
        if (!ss)
          return;
        ss->_selectedCategory = categoryKey;
        [ss _applyCategoryFilter];
        [ss _resizePopoverToSelectedCategory];
        if (ss.onCategoryChanged)
          ss.onCategoryChanged(categoryKey);
      });
  if (pill) {
    _categoryKeys = KKLaneCategoryKeys(lanes);
    _selectedCategory = KKResolveLaneCategory(lanes, requested);
    _categoryPill = pill;
    [self addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
      [pill.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [pill.topAnchor constraintEqualToAnchor:_categoryNavTopAnchor
                                     constant:_categoryNavTopInset],
      [pill.heightAnchor constraintEqualToConstant:kKKCategoryPillH],
    ]];
    top = pill.bottomAnchor;
    inset = KKPaddingMD;
  } else {
    _categoryKeys = nil;
    _selectedCategory = nil;
  }
  _stackTopConstraint = [_rowsScroll.topAnchor constraintEqualToAnchor:top
                                                              constant:inset];
  _stackTopConstraint.active = YES;
}

// (Re)seed the live per-lane values from the current `_lanes` snapshot, so the
// conditional-visibility cascade and page-resize start from the persisted
// values; live edits then overwrite single entries via the row's onValue.
- (void)_seedCurrentValues {
  _currentValuesByLabel =
      [NSMutableDictionary dictionaryWithCapacity:_lanes.count];
  _laneGatesVisibility = NO;
  for (KKLane *l in _lanes) {
    _currentValuesByLabel[l.label] = l.keyposes.firstObject.values ?: @[];
    if (l.visibleWhenLabel.length)
      _laneGatesVisibility = YES;
  }
}

// Show only the rows in the selected category (uncategorised rows show under
// every category) that also pass their conditional `visibleWhen` rule. With no
// selected category (one category or none) every category-eligible row shows.
// NSStackView collapses hidden arranged subviews, so visible rows pack to top.
- (void)_applyCategoryFilter {
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneLabels(_lanes, _currentValuesByLabel);
  NSString * (^catFor)(NSString *) = ^(NSString *label) {
    return self->_rowCategoryByLabel[label];
  };
  BOOL (^catHidden)(NSString *) = ^(NSString *label) {
    NSString *cat = catFor(label);
    return (BOOL)(self->_selectedCategory.length > 0 && cat.length > 0 &&
                  ![cat isEqualToString:self->_selectedCategory]);
  };
  // Editable rows obey both the category tab and the visibleWhen rule. Excluded
  // ("Animate" placeholder) rows aren't real lanes here, so only the category
  // tab applies to them.
  for (NSString *label in _rowsByLabel)
    _rowsByLabel[label].hidden =
        catHidden(label) || ![condVisible containsObject:label];
  for (NSString *label in _excludedRowsByLabel)
    _excludedRowsByLabel[label].hidden = catHidden(label);
  // An inline expression editor follows its value row's visibility exactly.
  for (NSString *label in _exprRowsByLabel)
    _exprRowsByLabel[label].hidden =
        catHidden(label) || ![condVisible containsObject:label];
  [self _refreshDynamicMaxRows];
}

// Rows built once at open keep the slider max they were built with; a lane
// whose max tracks another lane (maxControllerLabel, e.g. Mesh's colour count
// vs Type) needs its slider re-bounded whenever the controller changes. Runs on
// every visibility pass (which re-fires on any gating edit), so the max stays
// live.
- (void)_refreshDynamicMaxRows {
  for (KKLane *l in _lanes) {
    if (l.maxControllerLabel.length == 0 ||
        l.componentMaxByControllerValue.count == 0)
      continue;
    _KKStaticValueRow *row = _rowsByLabel[l.label];
    if (!row)
      continue;
    KKLane *adjusted = [self _laneWithDynamicMaxApplied:l];
    double effMax = adjusted.componentMax.count
                        ? adjusted.componentMax[0].doubleValue
                        : 0.0;
    [row applySliderMax:effMax];
  }
}

// The popover content's natural (unclamped) size for the current lanes /
// category / live values.
- (CGSize)_naturalContentSize {
  CGFloat h =
      [_KKStaticValuesPopoverView _heightForLanes:_lanes
                                   descriptorPath:_descriptorPath
                                       clipAspect:_clipAspect
                                    reserveHeader:_hasHeader
                                 selectedCategory:_selectedCategory
                                    valuesByLabel:_currentValuesByLabel];
  // The class-level height calc assumes every expression editor is COLLAPSED
  // (it has no instance state); add the extra height for each visible EXPANDED
  // one.
  CGFloat extra = kKKExprEditorExpandedH - kKKExprEditorRowH;
  for (NSString *label in _exprExpandedLabels) {
    NSView *ed = _exprRowsByLabel[label];
    if (ed && !ed.hidden)
      h += extra;
  }
  return NSMakeSize(
      [_KKStaticValuesPopoverView _popoverWidthForDescriptor:_descriptorPath],
      h);
}

// Clamp a natural content height to what fits on `screen` (with a margin and a
// sane floor). The overflow above the clamp is absorbed by the internal rows
// scroller; on a tall screen this returns the natural height unchanged.
- (CGFloat)_clampHeight:(CGFloat)naturalHeight toScreen:(NSScreen *)screen {
  NSScreen *scr = screen ?: NSScreen.mainScreen;
  CGFloat avail = scr.visibleFrame.size.height - kKKStaticPopoverScreenMargin;
  return MIN(naturalHeight, MAX(kKKStaticPopoverMinHeight, avail));
}

// Re-fit the popover to the current natural size, clamped to its screen so the
// rows scroll rather than running off a small display. No-op before the popover
// exists (initial sizing goes through -clampContentToScreenOfView:).
- (void)_applyContentSize {
  if (!_popover)
    return;
  CGSize s = [self _naturalContentSize];
  s.height =
      [self _clampHeight:s.height
                toScreen:_popover.contentViewController.view.window.screen];
  _popover.contentSize = s;
}

- (void)clampContentToScreenOfView:(NSView *)view {
  CGSize s = [self _naturalContentSize];
  s.height = [self _clampHeight:s.height toScreen:view.window.screen];
  [self setFrameSize:s];
}

// Resize the popover to hug the currently selected category's page so an
// uneven split (e.g. 1 Core row vs 3 Noise rows) doesn't leave empty space on
// the shorter page, and so revealing/hiding a conditional lane re-fits. No-op
// when there's no popover.
- (void)_resizePopoverToSelectedCategory {
  if (!_popover)
    return;
  [self _applyContentSize];
}

// While a colour swatch's shared panel is open, the panel is a separate window;
// the presenter's outside-click monitors would dismiss the popover on the first
// click into it (losing the row before the colour commits). Flag it so those
// monitors skip dismissal (see -suppressesPopoverDismiss); cleared when the
// panel closes.
- (void)_setColorEditing:(BOOL)editing {
  _colorPanelOpen = editing;
  // Closing the panel ends the session: commit the final colour now (a pending
  // burst may still be waiting on its debounce timer) as ONE undoable write.
  if (!editing)
    [self _flushColorPersist];
}

// (Re)arm the debounce: stash the latest colour and reset the timer, so a run
// of rapid drag callbacks collapses to a single persist once they stop.
- (void)_scheduleColorPersistForLabel:(NSString *)label
                               values:(NSArray<NSNumber *> *)values {
  _colorPendingLabel = label;
  _colorPendingValues = values;
  [_colorPersistTimer invalidate];
  _colorPersistTimer =
      [NSTimer scheduledTimerWithTimeInterval:0.2
                                       target:self
                                     selector:@selector(_flushColorPersist)
                                     userInfo:nil
                                      repeats:NO];
}

// Commit the pending colour as one ordinary (self-contained) undoable write.
- (void)_flushColorPersist {
  [_colorPersistTimer invalidate];
  _colorPersistTimer = nil;
  NSString *label = _colorPendingLabel;
  NSArray<NSNumber *> *values = _colorPendingValues;
  _colorPendingLabel = nil;
  _colorPendingValues = nil;
  if (values && _onHandleValue)
    _onHandleValue(label, values);
}

- (void)dealloc {
  [_colorPersistTimer invalidate];
  [_exprResultTimer invalidate];
}

// Presenter hook (KKTimelineLanesView+Popovers `_showPopoverWithContent`): when
// YES, the outside-click / scroll dismissal monitors treat every event as
// inside the popover, so a colour-panel interaction can't close it.
- (BOOL)suppressesPopoverDismiss {
  return _colorPanelOpen;
}

// A lane whose slider max reacts to another lane (maxControllerLabel): returns
// a copy with componentMax[0] swapped for the value looked up from the
// controller lane's current value, so the range tracks e.g. Mesh's Type.
// Unchanged lanes are returned as-is. Rebuilt whenever rows rebuild (Type
// change re-runs the visibility cascade), so the max stays reactive.
- (KKLane *)_laneWithDynamicMaxApplied:(KKLane *)lane {
  if (lane.maxControllerLabel.length == 0 ||
      lane.componentMaxByControllerValue.count == 0)
    return lane;
  NSArray<NSNumber *> *cv = _currentValuesByLabel[lane.maxControllerLabel];
  if (cv.count == 0)
    return lane;
  NSInteger idx = (NSInteger)llround(cv[0].doubleValue);
  if (idx < 0 || idx >= (NSInteger)lane.componentMaxByControllerValue.count)
    return lane;
  double effMax = lane.componentMaxByControllerValue[idx].doubleValue;
  double minV =
      lane.componentMin.count ? lane.componentMin[0].doubleValue : 0.0;
  if (effMax < minV)
    effMax = minV;
  double curMax =
      lane.componentMax.count ? lane.componentMax[0].doubleValue : effMax;
  if (effMax == curMax)
    return lane;
  KKLane *adjusted = [lane copy];
  adjusted.componentMax = @[ @(effMax) ];
  return adjusted;
}

// The parameter-link expression editor row: a `_KKStaticValueRow` editor row so
// its gutters line up with every value row for free (leading glyph slot, label/
// value columns, trailing reset column) instead of hand-rolled insets. Content
// = the KKCodeEditorView; left override = the insert-reference button; right
// override = the expand chevron. Edits persist through -_onSetLinkExpression
// WITHOUT a popover rebuild (boundary re-drive is suppressed), so typing
// survives.
- (NSView *)_makeExprEditorRowForLabel:(NSString *)label text:(NSString *)text {
  BOOL expanded = [_exprExpandedLabels containsObject:label];
  KKCodeEditorView *ed = [[KKCodeEditorView alloc] initWithFrame:NSZeroRect];
  ed.syntax = KKCodeSyntaxExpression; // set before codeText for the first paint
  // The model stores UUID-keyed refs (`${uuid.param}`); the editor shows the
  // friendly `${Clip.Param}` form. Translate on the way in, and back on
  // persist.
  [self _refreshLinkManifests];
  ed.codeText = [self _displayFromStored:(text ?: @"")];
  _exprEditorByLabel[label] = ed;
  __weak typeof(self) weak = self;
  ed.onChange = ^(NSString *code) {
    __strong typeof(weak) s = weak;
    NSString *stored = [s _storedFromDisplay:code];
    // Refresh the popover's cached `_lanes` entry so the result-strip timer
    // re-evaluates the NEW expression. The keypose popover suppresses the
    // rebuild echo (the _boundaryRedriveSuppress window that fixes the cmd-Z
    // crash), so unlike constants it never gets a fresh `_lanes` from
    // updateUnoptedLanes - update it here, in place, without a row rebuild.
    [s _updateCachedLaneExpression:stored forLabel:label];
    if (s->_onSetLinkExpression)
      s->_onSetLinkExpression(label, stored);
  };
  // Left override: the discovered-clip insert menu (drops a `${Clip.Param}`
  // token). Right override: the expand/collapse chevron. Both carry the label
  // on their identifier for the action, and are sized to the row's gutter
  // glyphs.
  NSButton *insertBtn = [NSButton
      buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus.circle"
                                accessibilityDescription:nil]
               target:self
               action:@selector(_insertReferenceMenu:)];
  insertBtn.bordered = NO;
  insertBtn.identifier = label;
  insertBtn.toolTip = KKLoc(
      @"Insert a clip reference, function or variable",
      @"Expression editor: insert-reference / function-reference button.");
  insertBtn.contentTintColor =
      [[NSColor accentMatchingHost] colorWithAlphaComponent:0.9];
  insertBtn.imageScaling = NSImageScaleProportionallyDown;
  insertBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [insertBtn.widthAnchor constraintEqualToConstant:15.0].active = YES;
  [insertBtn.heightAnchor constraintEqualToConstant:15.0].active = YES;

  NSButton *chevron = [NSButton
      buttonWithImage:[NSImage
                          imageWithSystemSymbolName:(expanded ? @"chevron.up"
                                                              : @"chevron.down")
                           accessibilityDescription:nil]
               target:self
               action:@selector(_toggleExprExpand:)];
  chevron.bordered = NO;
  chevron.identifier = label;
  chevron.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
  chevron.imageScaling = NSImageScaleProportionallyDown;
  chevron.translatesAutoresizingMaskIntoConstraints = NO;
  [chevron.widthAnchor constraintEqualToConstant:15.0].active = YES;
  [chevron.heightAnchor constraintEqualToConstant:15.0].active = YES;

  _KKStaticValueRow *row = [[_KKStaticValueRow alloc]
      initEditorRowWithContentView:ed
                          leftView:insertBtn
                         rightView:chevron
                        firstLineH:kKKExprEditorTextH
                            height:(expanded ? kKKExprEditorExpandedH
                                             : kKKExprEditorRowH)];
  return row;
}

// Reload the discovered link sources into the per-popover cache used by the
// display<->stored token transforms and the insert menu. Cheap directory read;
// called on editor install and each menu open, not on the render/keystroke
// path.
- (void)_refreshLinkManifests {
  // Scope the picker to the editing clip's project (empty documentID = unknown,
  // which returns everything - the legacy library-wide behaviour).
  _linkManifests = [KKLinkBus manifestsForDocumentID:_documentID];
}

// Model (`${uuid.rawLabel}`) <-> editor (`${Clip.Param}`) ref translation. The
// logic (token walk + name/uuid resolution) lives in the kit so the plugin's AI
// write-back and this editor share ONE source of truth; here we just bind it to
// the cached manifests.
- (NSString *)_displayFromStored:(NSString *)stored {
  return KKLinkDisplayExpressionFromStored(stored, _linkManifests);
}

- (NSString *)_storedFromDisplay:(NSString *)display {
  return KKLinkStoredExpressionFromDisplay(display, _linkManifests);
}

// Build and pop the reference-insert menu for the editor whose gutter button
// was clicked: one submenu per discovered clip (its display name + timecode),
// each listing that clip's referenceable params. Choosing one drops a friendly
// `${Clip.Param}` token into that editor (persisted uuid-keyed via onChange).
- (void)_insertReferenceMenu:(NSButton *)sender {
  NSString *label = sender.identifier;
  if (label.length == 0)
    return;
  [self _refreshLinkManifests];
  NSMenu *menu = [[NSMenu alloc] init];
  if (_linkManifests.count == 0) {
    NSMenuItem *empty = [[NSMenuItem alloc]
        initWithTitle:KKLoc(@"No other clips found",
                            @"Expression insert menu: empty state.")
               action:NULL
        keyEquivalent:@""];
    empty.enabled = NO;
    [menu addItem:empty];
  }
  for (KKLinkManifest *man in _linkManifests) {
    NSMenuItem *clipItem = [[NSMenuItem alloc] initWithTitle:man.displayName
                                                      action:NULL
                                               keyEquivalent:@""];
    // Per-clip thumbnail (baked by the source's inspector, keyed by its uuid)
    // so two same-named clips ("Shader @ 0:02" x2) are told apart visually.
    // Absent thumbnail = text-only item, unchanged.
    NSString *thumbPath = [KKLinkBus thumbnailPathForUUID:man.uuid];
    if (thumbPath.length) {
      NSImage *thumb = [[NSImage alloc] initWithContentsOfFile:thumbPath];
      if (thumb) {
        CGFloat h = 24.0; // ~menu row height; keep the source's aspect
        CGFloat w = MAX(1.0, thumb.size.height > 0
                                 ? h * thumb.size.width / thumb.size.height
                                 : h);
        thumb.size = NSMakeSize(round(w), h);
        clipItem.image = thumb;
      }
    }
    NSMenu *sub = [[NSMenu alloc] init];
    for (NSUInteger i = 0; i < man.paramLabels.count; i++) {
      NSString *paramDisplay = (i < man.paramDisplayNames.count)
                                   ? man.paramDisplayNames[i]
                                   : man.paramLabels[i];
      NSMenuItem *pit =
          [[NSMenuItem alloc] initWithTitle:paramDisplay
                                     action:@selector(_insertReferenceChosen:)
                              keyEquivalent:@""];
      pit.target = self;
      // Carry the editor label + the friendly token to insert (onChange maps it
      // back to the stable `${uuid.rawLabel}` for the model).
      pit.representedObject = @{
        @"label" : label,
        @"token" : [NSString
            stringWithFormat:@"${%@.%@}", man.displayName, paramDisplay]
      };
      [sub addItem:pit];
    }
    if (man.paramLabels.count == 0) {
      NSMenuItem *none = [[NSMenuItem alloc]
          initWithTitle:KKLoc(@"No parameters",
                              @"Expression insert menu: a source with no "
                              @"referenceable params.")
                 action:NULL
          keyEquivalent:@""];
      none.enabled = NO;
      [sub addItem:none];
    }
    // Manual cleanup. Auto-reconcile drops a source only once its clip is gone
    // AND the project is reopened (FCP gives the plugin no in-session delete
    // signal). For the rare straggler still listed after an in-session delete,
    // let the user remove it by hand. Harmless if it is actually live - it
    // re-advertises on its next render.
    [sub addItem:[NSMenuItem separatorItem]];
    NSMenuItem *rm = [[NSMenuItem alloc]
        initWithTitle:KKLoc(@"Remove from list",
                            @"Expression insert menu: manually drop a stale "
                            @"source clip from the reference list.")
               action:@selector(_removeReferenceSource:)
        keyEquivalent:@""];
    rm.target = self;
    rm.representedObject = man.uuid;
    if (@available(macOS 11.0, *))
      rm.image = [NSImage imageWithSystemSymbolName:@"xmark.circle"
                           accessibilityDescription:nil];
    [sub addItem:rm];
    clipItem.submenu = sub;
    [menu addItem:clipItem];
  }

  // Functions & variables reference: the WHOLE expression vocabulary, grouped
  // by category, each showing its signature + a one-line description, click to
  // insert. This is the discoverability surface - nothing is hidden behind
  // "you had to know it existed" (e.g. pingpong).
  if (menu.numberOfItems > 0)
    [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *fnHeader = [[NSMenuItem alloc]
      initWithTitle:KKLoc(@"Functions & variables",
                          @"Expression insert menu: reference section header.")
             action:NULL
      keyEquivalent:@""];
  fnHeader.enabled = NO;
  [menu addItem:fnHeader];
  for (NSString *categ in KKExprCatalogCategories()) {
    // categ stays English as the grouping key (matched against each entry's
    // "category"); localize only its shown title.
    NSMenuItem *catItem = [[NSMenuItem alloc]
        initWithTitle:KKLoc(categ, @"Expression insert menu: a category of "
                                   @"functions/variables (Variables/Math/...).")
               action:NULL
        keyEquivalent:@""];
    NSMenu *catSub = [[NSMenu alloc] init];
    for (NSDictionary<NSString *, NSString *> *e in KKExprCatalog()) {
      if (![e[@"category"] isEqualToString:categ])
        continue;
      NSMenuItem *it =
          [[NSMenuItem alloc] initWithTitle:e[@"signature"]
                                     action:@selector(_insertReferenceChosen:)
                              keyEquivalent:@""];
      it.target = self;
      it.attributedTitle = [self _exprCatalogTitleForEntry:e];
      it.toolTip = e[@"desc"];
      it.representedObject = @{@"label" : label, @"token" : e[@"insert"]};
      [catSub addItem:it];
    }
    catItem.submenu = catSub;
    [menu addItem:catItem];
  }

  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0, NSHeight(sender.bounds))
                          inView:sender];
}

// A reference-menu item title: the signature in normal menu text followed by
// its description dimmed + smaller, so the whole vocabulary reads at a glance.
- (NSAttributedString *)_exprCatalogTitleForEntry:
    (NSDictionary<NSString *, NSString *> *)e {
  NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
      initWithString:e[@"signature"]
          attributes:@{
            NSFontAttributeName : [NSFont menuFontOfSize:0],
            NSForegroundColorAttributeName : [NSColor labelColor]
          }];
  [s appendAttributedString:
          [[NSAttributedString alloc]
              initWithString:[@"    " stringByAppendingString:e[@"desc"]]
                  attributes:@{
                    NSFontAttributeName :
                        [NSFont menuFontOfSize:[NSFont smallSystemFontSize]],
                    NSForegroundColorAttributeName :
                        [NSColor secondaryLabelColor]
                  }]];
  return s;
}

- (void)_insertReferenceChosen:(NSMenuItem *)item {
  NSDictionary *info = item.representedObject;
  NSString *label = info[@"label"];
  NSString *token = info[@"token"];
  KKCodeEditorView *ed = _exprEditorByLabel[label];
  [ed insertReferenceText:token];
}

// Manually drop a source clip from the reference list (the "Remove from list"
// item in a source's submenu). Wipes its manifest / thumbnail / published
// curves; the next menu open rebuilds from what's left. Non-destructive for a
// live source - it re-advertises on its next render tick.
- (void)_removeReferenceSource:(NSMenuItem *)item {
  NSString *uuid = item.representedObject;
  if (uuid.length == 0)
    return;
  [KKLinkBus removeSourceForUUID:uuid];
  [self _refreshLinkManifests];
}

// Chevron on an expression-editor row: flip its label's expanded state, resize
// the editor row, swap the glyph, and re-fit the popover.
- (void)_toggleExprExpand:(NSButton *)sender {
  NSString *label = sender.identifier;
  if (label.length == 0)
    return;
  BOOL expanded = ![_exprExpandedLabels containsObject:label];
  if (expanded)
    [_exprExpandedLabels addObject:label];
  else
    [_exprExpandedLabels removeObject:label];
  _KKStaticValueRow *row = (_KKStaticValueRow *)_exprRowsByLabel[label];
  if ([row respondsToSelector:@selector(setEditorRowHeight:)])
    [row setEditorRowHeight:(expanded ? kKKExprEditorExpandedH
                                      : kKKExprEditorRowH)];
  sender.image = [NSImage
      imageWithSystemSymbolName:(expanded ? @"chevron.up" : @"chevron.down")
       accessibilityDescription:nil];
  [self _applyContentSize];
}

// Append an expression-editor row for `lane` to the end of the stack (used
// while building rows in order). No-op unless the lane carries an expression.
- (void)_installExprEditorForLane:(KKLane *)lane {
  if (!KKLaneHasExpressionEditor(lane))
    return;
  NSView *row = [self _makeExprEditorRowForLabel:lane.label
                                            text:lane.linkExpression];
  [_stack addArrangedSubview:row];
  [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
  _exprRowsByLabel[lane.label] = row;
  [self _updateExprResultForLane:lane]; // seed the strip immediately
  [self _ensureExprResultTimer];
}

// Evaluate `lane`'s expression at the current preview time and push the result
// to its inline editor's strip. Time comes from the popover's mini-viewer
// renderer (clip fraction / project seconds / duration); with no mini-viewer it
// falls to t=0. `value` + `${refs}` resolve exactly as the render does, so the
// strip shows what actually renders. No-op for a lane without an editor /
// expression.
- (void)_updateExprResultForLane:(KKLane *)lane {
  KKCodeEditorView *ed = _exprEditorByLabel[lane.label];
  if (!ed)
    return;
  if (lane.linkExpression.length == 0) {
    ed.resultText = nil;
    return;
  }
  // Evaluate against the LIVE displayed value (seeded from the shown keypose,
  // updated on every field / OSC edit) so the strip re-runs immediately - the
  // keypose popover never rebuilds `_lanes` on a value edit, so the cached
  // lane's keypose would otherwise stay stale until the popover is reopened.
  KKLane *evalLane = lane;
  NSArray<NSNumber *> *live = _currentValuesByLabel[lane.label];
  if (live.count) {
    evalLane = [lane copy];
    evalLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:live] ];
  }
  double frac = 0.0, tlSec = 0.0, dur = 0.0, start = 0.0;
  if ([_miniViewer.canvasDelegate isKindOfClass:[KKMiniViewerRenderer class]]) {
    KKMiniViewerRenderer *r =
        (KKMiniViewerRenderer *)_miniViewer.canvasDelegate;
    frac = r.editFraction;
    tlSec = r.linkTimelineSec;
    dur = r.clipDurationSeconds;
    start = r.clipTimelineStartSec;
  }

  // Where the dot sits (and where the readout is evaluated - they must agree):
  //  - constants mode: always the live playhead (linkTimelineSec back-solved to
  //  a
  //    clip fraction = clipProjectStartSec + playheadFraction*dur) - no keypose
  //    to anchor to, so it just tracks the scrub;
  //  - keypose mode: the playhead WHILE scrubbing/playing (so the dot + readout
  //    move with the live preview), pinging back to the keypose (editFraction)
  //    once the playhead settles.
  double playFrac = -1.0;
  if (dur > 0.0 && start >= 0.0 && tlSec >= 0.0)
    playFrac = MAX(0.0, MIN(1.0, (tlSec - start) / dur));
  double markerFrac;
  if (!_editsKeypose)
    markerFrac = playFrac;
  else if (_playheadMoving && playFrac >= 0.0)
    markerFrac = playFrac;
  else
    markerFrac = (frac >= 0.0 && frac <= 1.0) ? frac : -1.0;

  // Evaluate the readout AT the marker position so the number matches the dot:
  // t = clipStart + evalFrac*dur (= linkTimelineSec while moving; = the
  // keypose's own time once settled - not the stale scrub-release time).
  double evalFrac = (markerFrac >= 0.0) ? markerFrac : frac;
  double evalTl = (dur > 0.0 && start >= 0.0) ? start + evalFrac * dur : tlSec;
  NSArray<NSNumber *> *res =
      KKLinkResolvedLaneValue(evalLane, evalFrac, evalTl, dur);
  ed.resultText = [self _formatResultText:res];

  // Inline curve preview: sample the SAME expression across the whole clip
  // (fraction 0..1, t = clipStart + frac*dur), first component only, so it
  // reads identically in constants and keypose modes regardless of the current
  // playhead. A time-independent expression comes out flat, which is the honest
  // picture.
  static const NSInteger kSamples = 48;
  NSMutableArray<NSNumber *> *curve =
      [NSMutableArray arrayWithCapacity:kSamples];
  for (NSInteger i = 0; i < kSamples; i++) {
    double f = (double)i / (double)(kSamples - 1);
    double t = dur > 0.0 ? start + f * dur : tlSec;
    NSArray<NSNumber *> *v = KKLinkResolvedLaneValue(evalLane, f, t, dur);
    [curve addObject:v.firstObject ?: @0];
  }
  ed.sparklineSamples = curve;
  ed.sparklineMarker = markerFrac;
}

// "→ 135" (scalar) / "→ 105.2, 52.6" (multi-component), rounded to 2 decimals.
- (NSString *)_formatResultText:(NSArray<NSNumber *> *)values {
  if (values.count == 0)
    return nil;
  NSMutableArray<NSString *> *parts =
      [NSMutableArray arrayWithCapacity:values.count];
  for (NSNumber *n in values)
    [parts addObject:[NSString
                         stringWithFormat:@"%g", round(n.doubleValue * 100.0) /
                                                     100.0]];
  return [@"→ " stringByAppendingString:[parts componentsJoinedByString:@", "]];
}

// Refresh every visible expression lane's result strip (timer tick).
- (void)_updateAllExprResults {
  // Detect playhead motion once per tick (scrub/playback advances
  // linkTimelineSec; it holds at rest) so the keypose sparkline dot follows the
  // playhead while moving and pings back to the keypose when settled - matching
  // the mini-viewer's live preview. Computed here, not per-lane, so every lane
  // sees the same verdict.
  double tl = -1.0;
  if ([_miniViewer.canvasDelegate isKindOfClass:[KKMiniViewerRenderer class]])
    tl = ((KKMiniViewerRenderer *)_miniViewer.canvasDelegate).linkTimelineSec;
  _playheadMoving = (tl >= 0.0 && fabs(tl - _lastMarkerLinkSec) > 1e-6);
  _lastMarkerLinkSec = tl;
  for (KKLane *lane in _lanes)
    if (_exprEditorByLabel[lane.label])
      [self _updateExprResultForLane:lane];
}

// Start the result-refresh timer (once) so time-based expressions stay live.
// Weak self (no retain cycle); torn down in -releaseMiniViewer / -dealloc.
- (void)_ensureExprResultTimer {
  if (_exprResultTimer)
    return;
  __weak typeof(self) weak = self;
  _exprResultTimer =
      [NSTimer scheduledTimerWithTimeInterval:0.2
                                      repeats:YES
                                        block:^(NSTimer *t) {
                                          __strong typeof(weak) s = weak;
                                          if (!s) {
                                            [t invalidate];
                                            return;
                                          }
                                          [s _updateAllExprResults];
                                        }];
}

// Bring the inline editor in/out of an ALREADY-BUILT stack to match the current
// expression state for `label`, inserting it directly under `valueRow`. Drives
// the grow-in-place on Add/Remove. Returns YES iff a row was added/removed
// (structural change); a live text edit (still non-empty) leaves the existing
// editor alone. `label` is always a referenceable lane here (the row only
// exposes the menu for those), so presence is just `expr.length`.
- (BOOL)_syncExprEditorForLabel:(NSString *)label
                     expression:(NSString *)expr
                       afterRow:(_KKStaticValueRow *)valueRow {
  // nil = no expression (remove the editor); an empty string is a present-but-
  // empty expression (keep the editor open), so key on nil, not length.
  BOOL should = (expr != nil);
  NSView *existing = _exprRowsByLabel[label];
  if (should && !existing) {
    NSView *row = [self _makeExprEditorRowForLabel:label text:expr];
    NSInteger idx = [_stack.arrangedSubviews indexOfObject:valueRow];
    if (idx == NSNotFound)
      [_stack addArrangedSubview:row];
    else
      [_stack insertArrangedSubview:row atIndex:idx + 1];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _exprRowsByLabel[label] = row;
    [self _ensureExprResultTimer]; // populate the result strip on the next tick
    return YES;
  }
  if (!should && existing) {
    [_stack removeArrangedSubview:existing];
    [existing removeFromSuperview];
    [_exprRowsByLabel removeObjectForKey:label];
    [_exprEditorByLabel removeObjectForKey:label];
    return YES;
  }
  return NO; // no structural change (text edit / already correct)
}

- (BOOL)_syncExprEditorForLane:(KKLane *)lane
                      afterRow:(_KKStaticValueRow *)valueRow {
  return [self _syncExprEditorForLabel:lane.label
                            expression:(KKLaneHasExpressionEditor(lane)
                                            ? lane.linkExpression
                                            : nil)afterRow:valueRow];
}

// Push the lane's current (stored) expression into its inline editor as an
// EXTERNAL change, so an undo/redo of a committed edit reaches the editor. Uses
// -applyExternalText: which is focus-safe (skips a live uncommitted typing
// burst so it never clobbers what the user is mid-typing) and clears the
// editor's local undo once applied. No-op when the lane has no editor.
//
// DEFERRED to the next runloop, and NO disk read here: this is called from
// inside the synchronous undo -> _refresh -> updateUnoptedLanes chain, often
// while the editor's text view is first responder mid-edit. Mutating it (and,
// worse, doing app-group disk I/O) re-entrantly from that chain crashed FCP on
// cmd-Z. The dispatch hops out of the chain; the stored->display mapping uses
// the cached manifests (a stale friendly name is harmless and refreshes on the
// next edit).
- (void)_resyncExprEditorTextForLane:(KKLane *)lane {
  NSString *label = lane.label;
  if (!_exprEditorByLabel[label])
    return;
  NSString *stored = lane.linkExpression ?: @"";
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    KKCodeEditorView *ed = s ? s->_exprEditorByLabel[label] : nil;
    if (!ed)
      return;
    [ed applyExternalText:[s _displayFromStored:stored]];
  });
}

// Update the popover's cached `_lanes` entry for `label` so a subsequent resize
// (_applyContentSize -> _heightForLanes:_lanes) computes the new height. A copy
// is mutated (never the shared model lane). Needed for the keypose popover,
// which has no lanes-view reconcile to refresh _lanes on an expression toggle.
- (void)_updateCachedLaneExpression:(NSString *)expr
                           forLabel:(NSString *)label {
  NSMutableArray<KKLane *> *ml = [_lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)ml.count; i++)
    if ([ml[i].label isEqualToString:label]) {
      KKLane *c = [ml[i] copy];
      // An empty expression stays present (passthrough) so the inline editor
      // remains open after the user clears the text; only nil closes it.
      c.linkExpression = expr;
      ml[i] = c;
      _lanes = ml;
      return;
    }
}

- (_KKStaticValueRow *)_makeRowForLane:(KKLane *)lane {
  lane = [self _laneWithDynamicMaxApplied:lane];
  BOOL showsRemove = (_rowRemoveHandler != nil);
  // Non-animatable lanes are value-only: no "make animatable" gutter button.
  BOOL showsAdd = (_rowAddToAnimatedHandler != nil && lane.animatable);
  BOOL showsSmooth = (lane.spatialCurvable && _editsKeypose);
  // A constant row in the add-to-animated (constants) popover has no gutter
  // button, but the animatable rows do - reserve the column so all labels +
  // value controls line up (e.g. a Sketch group's constant Strokes/Seed rows
  // align with the animatable Roughness/Bowing rows).
  BOOL reservesGutter =
      (_rowAddToAnimatedHandler != nil) && !showsAdd && !showsRemove;
  _KKStaticValueRow *row = [[_KKStaticValueRow alloc]
            initWithLane:lane
             showsRemove:showsRemove
      showsAddToAnimated:showsAdd
             showsSmooth:showsSmooth
          reservesGutter:reservesGutter
        labelColumnWidth:_labelColumnWidth
            contentWidth:[_KKStaticValuesPopoverView
                             _popoverWidthForDescriptor:_descriptorPath]];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  NSString *label = lane.label;
  __weak typeof(self) weak = self;
  if (showsRemove)
    row.onRemove = ^{
      __strong typeof(weak) s = weak;
      if (s->_rowRemoveHandler)
        s->_rowRemoveHandler(label);
    };
  if (showsAdd)
    row.onAddToAnimated = ^{
      __strong typeof(weak) s = weak;
      if (s->_rowAddToAnimatedHandler)
        s->_rowAddToAnimatedHandler(label);
    };
  // Lanes that opt into `componentsScaleWithMedia` store a normalised 0..1
  // value but display it as pixels: even-index components (W/X-like) use media
  // width; odd-index (H/Y-like) use height, with the inverse on typed input.
  // Covers Crop (W,H,X,Y), Position X/Y, Anchor X/Y. The componentUnits string
  // is cosmetic and does NOT drive this - a lane can show "px" while storing
  // raw pixels (Glow Radius). Returns 0 until the feed resolves, which the row
  // treats as "fall back to raw norm".
  if (lane.componentsScaleWithMedia) {
    NSArray<NSString *> *units = lane.componentUnits;
    row.componentScale = ^double(NSInteger i) {
      // A "%" component is a literal percentage - never media-scaled. Lets one
      // lane mix px positions (X/Y) with a % size (a mesh point's Spread).
      if (i < (NSInteger)units.count && [units[i] isEqualToString:@"%"])
        return 1.0;
      __strong typeof(weak) s = weak;
      CGSize m = s ? s->_miniViewer.sourceMediaSize : CGSizeZero;
      double scale = (i % 2 == 0) ? m.width : m.height;
      return scale;
    };
    [row applyLane:lane];
  }
  row.onValue = ^(NSArray<NSNumber *> *values) {
    __strong typeof(weak) s = weak;
    // Track the live value; if this lane gates others (e.g. Mode -> Solid /
    // Gradient), re-run the visibility cascade and re-fit the popover so the
    // dependent rows reveal/hide on the same tick.
    s->_currentValuesByLabel[label] = values;
    if (s->_laneGatesVisibility) {
      [s _applyCategoryFilter];
      [s _resizePopoverToSelectedCategory];
    }
    // Live preview: feed the edit into the renderer + redraw the canvas
    // (persist stays coalesced via _onHandleValue downstream).
    id<KKMiniViewerDelegate> del = s->_miniViewer.canvasDelegate;
    if ([del
            respondsToSelector:@selector(
                                   miniViewer:applyConstantValues:forLabel:)]) {
      [del miniViewer:s->_miniViewer applyConstantValues:values forLabel:label];
      [s->_miniViewer setNeedsDisplay:YES];
      [s->_miniViewer setHandlesNeedDisplay];
    }
    if (s->_onHandleValue) {
      if (s->_colorPanelOpen)
        // Async colour drag: preview above already ran; coalesce the persist.
        [s _scheduleColorPersistForLabel:label values:values];
      else
        s->_onHandleValue(label, values);
    }
  };
  row.onCodeChanged = ^(NSString *code) {
    __strong typeof(weak) s = weak;
    if (s.onHandleCode)
      s.onHandleCode(label, code);
  };
  row.onCodeSectionsChanged =
      ^(NSArray<NSDictionary<NSString *, NSString *> *> *sections) {
        __strong typeof(weak) s = weak;
        if (s.onHandleCodeSections)
          s.onHandleCodeSections(label, sections);
      };
  row.onDragBegin = ^{
    __strong typeof(weak) s = weak;
    if (s->_onDragBegin)
      s->_onDragBegin();
  };
  row.onDragEnd = ^{
    __strong typeof(weak) s = weak;
    if (s->_onDragEnd)
      s->_onDragEnd();
  };
  if (showsSmooth)
    row.onSmoothToggled = ^(BOOL on) {
      __strong typeof(weak) s = weak;
      if (s->_onSmoothToggled)
        s->_onSmoothToggled(label, on);
    };
  if (lane.aspectLinkable)
    row.onLinkToggled = ^(BOOL on) {
      __strong typeof(weak) s = weak;
      if (s->_onLinkToggled)
        s->_onLinkToggled(label, on);
    };
  // Parameter linking: right-click "Add / Remove Expression" on the label.
  row.onSetLinkExpression = ^(NSString *_Nullable expr) {
    __strong typeof(weak) s = weak;
    // Persist through the host.
    if (s->_onSetLinkExpression)
      s->_onSetLinkExpression(label, expr);
    // Grow/shrink IN PLACE (works for both the constants and keypose popovers -
    // popover-level, so it doesn't depend on the lanes-view reconcile that only
    // runs for constants). Update the cached lane so the resize computes the
    // new height, sync the editor under the row, then re-fit. Idempotent, so
    // the constants path's later reconcile is a no-op.
    [s _updateCachedLaneExpression:expr forLabel:label];
    _KKStaticValueRow *r = s->_rowsByLabel[label];
    if (r && [s _syncExprEditorForLabel:label expression:expr afterRow:r])
      [s _applyContentSize];
  };
  // Right-click "Format Expression": tidy the live editor text in place. Parses
  // the friendly display text (refs round-trip verbatim) and rewrites it
  // normalized; a parse error no-ops. onChange then re-stores the uuid form.
  row.onFormatExpression = ^{
    __strong typeof(weak) s = weak;
    KKCodeEditorView *ed = s->_exprEditorByLabel[label];
    [ed formatUsing:^NSString *(NSString *code) {
      KKLinkExpr *e = [KKLinkExpr compile:code error:NULL];
      return e ? [e formattedSource] : nil;
    }];
  };
  if (lane.valueType == KKLaneValueTypeColor ||
      lane.valueType == KKLaneValueTypeGradient ||
      lane.valueType == KKLaneValueTypeColorPoint)
    row.onColorEditing = ^(BOOL editing) {
      __strong typeof(weak) s = weak;
      [s _setColorEditing:editing];
    };
  // Only the keypose editor propagates a gradient type change to every keypose
  // (the lane is animated). In the constants editor the row commits it like any
  // other single-keypose value.
  if (_editsKeypose && lane.valueType == KKLaneValueTypeGradient &&
      lane.gradientShowsTypeAngle)
    row.onGradientTypeChanged = ^(NSInteger type) {
      __strong typeof(weak) s = weak;
      if (s->_onGradientTypeChanged)
        s->_onGradientTypeChanged(label, type);
    };
  // A lockable colour row: restore its transient lock state (survives rebuilds
  // via the popover's label set) and track toggles for a later palette reroll.
  if (lane.paletteLockable) {
    if (!_lockedColorLabels)
      _lockedColorLabels = [NSMutableSet set];
    [row applyPaletteLock:[_lockedColorLabels containsObject:label]];
    row.onPaletteLockToggled = ^(BOOL locked) {
      __strong typeof(weak) s = weak;
      if (!s)
        return;
      if (locked)
        [s->_lockedColorLabels addObject:label];
      else
        [s->_lockedColorLabels removeObject:label];
    };
  }
  if (lane.paletteGeneratorBar) {
    row.onPaletteGenerate = ^(NSInteger mode) {
      __strong typeof(weak) s = weak;
      [s _generatePaletteWithMode:mode];
    };
    row.onPaletteRefine = ^{
      __strong typeof(weak) s = weak;
      [s _refinePalette];
    };
  }
  return row;
}

// The conditionally-visible, lockable colour lanes, in row order - the set the
// generator acts on.
- (NSArray<NSString *> *)_visiblePaletteLabels {
  NSSet<NSString *> *visible =
      KKConditionalVisibleLaneLabels(_lanes, _currentValuesByLabel);
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (KKLane *lane in _lanes)
    if (lane.valueType == KKLaneValueTypeColor && lane.paletteLockable &&
        [visible containsObject:lane.label])
      [labels addObject:lane.label];
  return labels;
}

// The visible lockable colour labels split into INDEPENDENT palette journeys by
// `paletteGroup` (in first-seen row order). Lanes with a nil group share one
// journey (legacy). A host with several distinct colour properties gives each a
// group so they reroll as separate cohesive palettes.
- (NSArray<NSArray<NSString *> *> *)_visiblePaletteGroups {
  NSSet<NSString *> *visible =
      KKConditionalVisibleLaneLabels(_lanes, _currentValuesByLabel);
  NSMutableArray<NSMutableArray<NSString *> *> *groups = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byGroup =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *legacy = nil;
  for (KKLane *lane in _lanes) {
    if (lane.valueType != KKLaneValueTypeColor || !lane.paletteLockable ||
        ![visible containsObject:lane.label])
      continue;
    if (lane.paletteGroup.length) {
      NSMutableArray<NSString *> *g = byGroup[lane.paletteGroup];
      if (!g) {
        g = [NSMutableArray array];
        byGroup[lane.paletteGroup] = g;
        [groups addObject:g];
      }
      [g addObject:lane.label];
    } else {
      if (!legacy) {
        legacy = [NSMutableArray array];
        [groups addObject:legacy];
      }
      [legacy addObject:lane.label];
    }
  }
  return groups;
}

- (NSColor *)_currentColorForLabel:(NSString *)label {
  NSArray<NSNumber *> *v = _currentValuesByLabel[label];
  if (v.count < 3)
    return [NSColor whiteColor];
  return [NSColor colorWithSRGBRed:v[0].doubleValue
                             green:v[1].doubleValue
                              blue:v[2].doubleValue
                             alpha:v.count > 3 ? v[3].doubleValue : 1.0];
}

// Parallel to `labels`: the locked colour (NSColor) or NSNull for each.
- (NSArray *)_lockedArrayForLabels:(NSArray<NSString *> *)labels {
  NSMutableArray *locked = [NSMutableArray arrayWithCapacity:labels.count];
  for (NSString *label in labels)
    [locked addObject:([_lockedColorLabels containsObject:label]
                           ? (id)[self _currentColorForLabel:label]
                           : (id)[NSNull null])];
  return locked;
}

// Write `colors[i]` into `labels[i]` (skipping locked labels): preview + row
// swatch now, then persist every changed swatch as ONE undo entry. The per-lane
// drag path can't be used - it defers to a single pending label per bracket, so
// only the last write would survive; the batch committer exists for this.
- (void)_commitPaletteColors:(NSArray<NSColor *> *)colors
                   forLabels:(NSArray<NSString *> *)labels {
  id<KKMiniViewerDelegate> del = _miniViewer.canvasDelegate;
  BOOL previews = [del
      respondsToSelector:@selector(miniViewer:applyConstantValues:forLabel:)];
  NSMutableArray<NSString *> *changed = [NSMutableArray array];
  NSMutableArray<NSArray<NSNumber *> *> *changedVals = [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
    NSString *label = labels[i];
    if ([_lockedColorLabels containsObject:label])
      continue;
    NSColor *c = [colors[i] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]
                     ?: colors[i];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [c getRed:&r green:&g blue:&b alpha:&a];
    NSArray<NSNumber *> *vals = @[ @(r), @(g), @(b), @(a) ];
    _currentValuesByLabel[label] = vals;
    [_rowsByLabel[label] applyValues:vals];
    if (previews)
      [del miniViewer:_miniViewer applyConstantValues:vals forLabel:label];
    [changed addObject:label];
    [changedVals addObject:vals];
  }
  if (previews) {
    [_miniViewer setNeedsDisplay:YES];
    [_miniViewer setHandlesNeedDisplay];
  }
  if (changed.count == 0)
    return;
  if (_onCommitBatch)
    _onCommitBatch(changed, changedVals);
  else if (_onHandleValue)
    for (NSInteger i = 0; i < (NSInteger)changed.count; i++)
      _onHandleValue(changed[i], changedVals[i]);
}

// Reroll the visible palette in `mode`. Locked swatches act as anchors that the
// regenerated colours interpolate between (see KKPaletteGenerator).
- (void)_generatePaletteWithMode:(NSInteger)mode {
  NSMutableArray<NSString *> *allLabels = [NSMutableArray array];
  NSMutableArray<NSColor *> *allColors = [NSMutableArray array];
  for (NSArray<NSString *> *labels in [self _visiblePaletteGroups]) {
    if (labels.count == 0)
      continue;
    // Each group is its own independent journey.
    NSArray<NSColor *> *palette = [KKPaletteGenerator
        paletteWithMode:(KKPaletteMode)mode
                  count:(NSInteger)labels.count
                 locked:[self _lockedArrayForLabels:labels]];
    [allLabels addObjectsFromArray:labels];
    [allColors addObjectsFromArray:palette];
  }
  if (allLabels.count)
    [self _commitPaletteColors:allColors forLabels:allLabels];
}

// Nudge the current visible palette instead of rerolling (locked kept). Per
// group, so each colour property stays its own palette.
- (void)_refinePalette {
  NSMutableArray<NSString *> *allLabels = [NSMutableArray array];
  NSMutableArray<NSColor *> *allColors = [NSMutableArray array];
  for (NSArray<NSString *> *labels in [self _visiblePaletteGroups]) {
    if (labels.count == 0)
      continue;
    NSMutableArray<NSColor *> *current = [NSMutableArray array];
    for (NSString *label in labels)
      [current addObject:[self _currentColorForLabel:label]];
    NSArray<NSColor *> *palette = [KKPaletteGenerator
        refinedPaletteFrom:current
                    locked:[self _lockedArrayForLabels:labels]];
    [allLabels addObjectsFromArray:labels];
    [allColors addObjectsFromArray:palette];
  }
  if (allLabels.count)
    [self _commitPaletteColors:allColors forLabels:allLabels];
}

- (void)applyDefaultsProvider:
    (NSArray<NSNumber *> * (^)(NSString *label))provider {
  _defaultsProvider = [provider copy];
  if (!provider)
    return;
  for (NSString *label in _rowsByLabel)
    _rowsByLabel[label].defaultValues = provider(label);
}

- (void)applyExcludedLabels:(NSArray<NSString *> *)labels
                    message:(NSString *)message
                  onAnimate:(void (^)(NSString *))onAnimate {
  _excludedMessage = [message copy];
  _onAnimate = [onAnimate copy];
  if (labels.count == 0)
    return;
  // Swap the excluded property's editable row for a message+Animate row at
  // the SAME stack position, so the original property order is preserved
  // (heights match → no resize).
  for (NSString *label in labels) {
    _KKStaticValueRow *old = _rowsByLabel[label];
    if (!old)
      continue;
    NSInteger idx = [_stack.arrangedSubviews indexOfObject:old];
    if (idx == NSNotFound)
      continue;
    [_stack removeArrangedSubview:old];
    [old removeFromSuperview];
    [_rowsByLabel removeObjectForKey:label];

    // The lane carries the user-facing display label (its identity `label` may
    // be a stable key like a shader uniform name); resolve it so the excluded
    // row reads the same name as the editable row it replaced.
    NSString *displayLabel = nil;
    for (KKLane *l in _lanes)
      if ([l.label isEqualToString:label]) {
        displayLabel = l.displayLabel;
        break;
      }
    _KKExcludedRow *row =
        [[_KKExcludedRow alloc] initWithLabel:label
                                 displayLabel:displayLabel
                                      message:message
                                       gutter:(_rowRemoveHandler != nil)];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *cap = [label copy];
    row.onAnimate = ^{
      if (onAnimate)
        onAnimate(cap);
    };
    [_stack insertArrangedSubview:row atIndex:idx];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    [row.heightAnchor constraintEqualToConstant:kFloatRowH].active = YES;
    _excludedRowsByLabel[label] = row;
  }
  [self _applyCategoryFilter];
}

// Tear down the row stack only (mini-viewer + header are separate subviews,
// left intact) and rebuild editable rows in lane order, re-apply reset
// defaults, then swap the keypose-less lanes to Animate rows in place. Lets
// the in-place update path (add / remove / navigate) re-render rows without
// reopening the popover - reopening blinks the MTKView. The popover height was
// budgeted at first-open for all-editable rows, so a row growing back from
// excluded to editable always fits; no resize needed.
- (void)rebuildRowsWithLanes:(NSArray<KKLane *> *)lanes
              excludedLabels:(NSArray<NSString *> *)excluded {
  // Preserve code-editor rows across the rebuild: their editor holds live tab
  // state (active tab + unsaved text) that recreating would destroy, and a code
  // row is non-animatable so nothing about its appearance changes here.
  NSMutableDictionary<NSString *, _KKStaticValueRow *> *keepCode =
      [NSMutableDictionary dictionary];
  for (NSString *label in _rowsByLabel)
    if (_rowsByLabel[label].isCodeRow)
      keepCode[label] = _rowsByLabel[label];
  NSArray *kept = keepCode.allValues;
  for (NSView *v in [_stack.arrangedSubviews copy]) {
    [_stack removeArrangedSubview:v];
    if (![kept containsObject:v])
      [v removeFromSuperview];
  }
  [_rowsByLabel removeAllObjects];
  [_excludedRowsByLabel removeAllObjects];
  [_exprRowsByLabel
      removeAllObjects]; // editors were removed with the stack above
  [_exprEditorByLabel removeAllObjects]; // re-tracked per editor rebuild
  // NB: _exprExpandedLabels persists so the user's expand choice survives
  // rebuilds.
  _lanes = [lanes copy];
  [self _seedCurrentValues];
  _labelColumnWidth = [_KKStaticValueRow labelColumnWidthForLanes:lanes];
  NSMutableDictionary<NSString *, NSString *> *catByLabel =
      [NSMutableDictionary dictionary];
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *reused = keepCode[lane.label];
    _KKStaticValueRow *row = reused ?: [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    if (!reused) // a reused row already has its stack-width constraint
      [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
    [self _installExprEditorForLane:lane];
    if (lane.categoryKey.length)
      catByLabel[lane.label] = lane.categoryKey;
  }
  // Tear down any PRESERVED code row the new lane set didn't reuse (e.g. the
  // constants "Shader" code lane when reconfiguring into a keypose popover,
  // whose lanes don't include it). It was held back from the
  // removeFromSuperview sweep above so its live editor state could be reused;
  // when it isn't, it would otherwise float over the new rows ("bleeding").
  NSArray<_KKStaticValueRow *> *reusedRows = _rowsByLabel.allValues;
  for (_KKStaticValueRow *codeRow in kept)
    if (![reusedRows containsObject:codeRow])
      [codeRow removeFromSuperview];
  _rowCategoryByLabel = catByLabel;
  if (_defaultsProvider)
    for (NSString *label in _rowsByLabel)
      _rowsByLabel[label].defaultValues = _defaultsProvider(label);
  // Rebuild the category nav too (not just the rows): a re-target to a
  // different layer can change the whole category SET (e.g. a Core/Points layer
  // -> a Stroke layer), so the pills must follow - otherwise the old tabs
  // persist and the category filter hides every row of the new layer.
  // Re-resolves _selectedCategory to a surviving tab. Mirrors
  // updateUnoptedLanes (constants).
  [self _rebuildCategoryNavForLanes:lanes initialCategory:_selectedCategory];
  [self _applyCategoryFilter];
  [self applyExcludedLabels:excluded
                    message:_excludedMessage
                  onAnimate:_onAnimate];
  // Re-fit the popover to the rebuilt rows (a re-target / add / remove can
  // change the row count). No-op until the popover exists (the initial build's
  // rebuild calls run before showRelative sizes it). Uses the authoritative
  // height calc, same as the category-switch resize.
  [self _resizePopoverToSelectedCategory];
}

// Live (per-tick) UI update during a mini-viewer handle drag - refresh the
// matching row's fields/slider WITHOUT persisting (the heavy timeline/FCP
// write stays coalesced to drag end). The crop size readout lives in the
// canvas overlay and redraws itself.
// Resolve a row by label, tolerant of the plain-vs-tagged mismatch: the
// mini-viewer handle reports the PLAIN lane label ("Position") from the
// selected owner's timeline, while rows in a merged multi-owner popover are
// keyed by the tagged label ("Position\x1f<ownerID>"). The popover's rows are
// scoped to one owner, so matching by plain label is unambiguous. An exact key
// hit (field edits / single-owner) is returned first, so this is a no-op there.
- (_KKStaticValueRow *)_rowForLabelTolerant:(NSString *)label {
  _KKStaticValueRow *row = _rowsByLabel[label];
  if (row)
    return row;
  NSString *plain = KKPlainLaneLabel(label);
  for (NSString *key in _rowsByLabel)
    if ([KKPlainLaneLabel(key) isEqualToString:plain])
      return _rowsByLabel[key];
  return nil;
}

- (void)liveUpdateValues:(NSArray<NSNumber *> *)values
                forLabel:(NSString *)label {
  [[self _rowForLabelTolerant:label] applyValues:values];
  // Keep the live-value cache current for OSC drags too (the row's own onValue
  // does this for field edits), so an expression lane's result strip re-runs
  // against the value being dragged instead of a stale cached keypose.
  _currentValuesByLabel[label] = values;
}

- (nullable NSView *)rowViewForLabel:(NSString *)label {
  return [self _rowForLabelTolerant:label];
}

- (void)guideBeginConstantDrag {
  if (_onDragBegin)
    _onDragBegin();
}

- (void)guideApplyConstantValues:(NSArray<NSNumber *> *)values
                        forLabel:(NSString *)label {
  // Same body as _KKStaticValueRow.onValue: live preview into the renderer +
  // canvas redraw + move the row's knob/fields, persist coalesced downstream.
  id<KKMiniViewerDelegate> del = _miniViewer.canvasDelegate;
  if ([del respondsToSelector:@selector(
                                  miniViewer:applyConstantValues:forLabel:)]) {
    [del miniViewer:_miniViewer applyConstantValues:values forLabel:label];
    [_miniViewer setNeedsDisplay:YES];
    [_miniViewer setHandlesNeedDisplay];
  }
  [self liveUpdateValues:values forLabel:label];
  if (_onHandleValue)
    _onHandleValue(label, values);
}

- (void)guideEndConstantDrag {
  if (_onDragEnd)
    _onDragEnd();
}

- (KKSliderView *)_guideSliderForLabel:(NSString *)label {
  // Tolerant lookup: owner-scoped lanes (e.g. Draw On End) carry a composite
  // "<plain>\x1f<layerID>" key, so an exact match would miss.
  NSView *v = [[self _rowForLabelTolerant:label] guideSliderView];
  return [v isKindOfClass:[KKSliderView class]] ? (KKSliderView *)v : nil;
}

- (NSRect)guideSliderTrackScreenRectForLabel:(NSString *)label {
  return [[self _guideSliderForLabel:label] trackScreenRect];
}

- (NSRect)guideSliderKnobScreenRectForLabel:(NSString *)label {
  return [[self _guideSliderForLabel:label] knobScreenRect];
}

- (CGFloat)guideSliderScreenXForValue:(double)value forLabel:(NSString *)label {
  return [[self _guideSliderForLabel:label] screenXForValue:value];
}

- (double)guideSliderValueForScreenX:(CGFloat)screenX
                            forLabel:(NSString *)label {
  return [[self _guideSliderForLabel:label] valueForScreenX:screenX];
}

- (NSRect)guideChoicePillScreenRectForLabel:(NSString *)label
                                    atIndex:(NSInteger)index {
  return [[self _rowForLabelTolerant:label]
      guideChoicePillScreenRectForIndex:index];
}

- (NSRect)guideAddToAnimatedButtonScreenRectForLabel:(NSString *)label {
  return [[self _rowForLabelTolerant:label] guideAddToAnimatedButtonScreenRect];
}

- (NSRect)guideCategoryPillScreenRectForKey:(NSString *)key {
  NSInteger idx = [_categoryKeys indexOfObject:key];
  if (!_categoryPill || idx == NSNotFound)
    return NSZeroRect;
  return [_categoryPill guidePillScreenRectAtIndex:idx];
}

- (void)guideScrollRowIntoViewForLabel:(NSString *)label {
  _KKStaticValueRow *row = [self _rowForLabelTolerant:label];
  if (row && !row.hidden)
    [row scrollRectToVisible:row.bounds];
}

// Programmatically switch the open popover to `key` (updating the nav pill's
// selected segment, the row filter, and the height) WITHOUT firing
// onCategoryChanged - a guide forces a known tab without tripping its own
// category trigger or the remember. No-op if the category isn't present.
- (void)guideSelectCategory:(NSString *)key {
  NSInteger idx = [_categoryKeys indexOfObject:key];
  if (!_categoryPill || idx == NSNotFound ||
      [_selectedCategory isEqualToString:key])
    return;
  for (NSInteger i = 0; i < (NSInteger)_categoryKeys.count; i++)
    [_categoryPill setState:(i == idx) atIndex:i];
  _selectedCategory = [key copy];
  [self _applyCategoryFilter];
  [self _resizePopoverToSelectedCategory];
}

- (NSRect)guideFieldScreenRectForLabel:(NSString *)label
                             component:(NSInteger)component {
  NSView *f =
      [[self _rowForLabelTolerant:label] guideFieldViewForComponent:component];
  NSWindow *w = f.window;
  if (!f || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[f convertRect:f.bounds toView:nil]];
}

- (void)setGuideFieldEditHandlerForLabel:(NSString *)label
                                 handler:(void (^)(NSInteger, double))handler {
  [self _rowForLabelTolerant:label].onGuideFieldEdit = handler;
}

- (void)guideCommitFieldForLabel:(NSString *)label
                       component:(NSInteger)component {
  [[self _rowForLabelTolerant:label] guideCommitFieldForComponent:component];
}

- (void)updateUnoptedLanes:(NSArray<KKLane *> *)lanes {
  NSSet<NSString *> *newSet =
      [NSSet setWithArray:[lanes valueForKeyPath:@"label"]];

  NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
  for (NSString *label in _rowsByLabel)
    if (![newSet containsObject:label])
      [toRemove addObject:label];
  for (NSString *label in toRemove) {
    _KKStaticValueRow *row = _rowsByLabel[label];
    [_stack removeArrangedSubview:row];
    [row removeFromSuperview];
    [_rowsByLabel removeObjectForKey:label];
    // Drop its inline expression editor too, if any (the label is gone).
    NSView *ed = _exprRowsByLabel[label];
    if (ed) {
      [_stack removeArrangedSubview:ed];
      [ed removeFromSuperview];
      [_exprRowsByLabel removeObjectForKey:label];
      [_exprEditorByLabel removeObjectForKey:label];
    }
  }

  _lanes = [lanes copy];
  [self _seedCurrentValues];
  _labelColumnWidth = [_KKStaticValueRow labelColumnWidthForLanes:lanes];
  // Make a row for each newly-constant lane (append for now) and refresh the
  // existing ones.
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *existing = _rowsByLabel[lane.label];
    // A reused row whose rendering STRUCTURE changed (palette bar <-> value
    // editor, code <-> non-code, seed <-> field, float <-> percent/choice, unit
    // or field-count change) can't be updated in place - drop it so it is
    // remade below. Metadata-only changes (range, values) are handled by
    // applyLane.
    //
    // Also remake when the shared label column moved: a lane added/removed/
    // relabelled above can change the widest name, and `_labelColumnWidth` was
    // just recomputed. applyLane can't restretch the row's title-width
    // constraint, so a reused row would keep its old column and start its value
    // control at a different x than the rows around it (misaligned sliders).
    BOOL columnShifted =
        existing && fabs(existing.labelColumnWidth - _labelColumnWidth) > 0.5;
    if (existing &&
        (![existing renderShapeMatchesLane:lane] || columnShifted)) {
      [_stack removeArrangedSubview:existing];
      [existing removeFromSuperview];
      [_rowsByLabel removeObjectForKey:lane.label];
      // Drop its inline expression editor too (a remake reinstalls a fresh
      // one).
      NSView *oldEd = _exprRowsByLabel[lane.label];
      if (oldEd) {
        [_stack removeArrangedSubview:oldEd];
        [oldEd removeFromSuperview];
        [_exprRowsByLabel removeObjectForKey:lane.label];
        [_exprEditorByLabel removeObjectForKey:lane.label];
      }
      existing = nil;
    }
    if (existing) {
      [existing applyLane:lane]; // reflect external edits (values + range)
      // Grow/shrink in place when an expression was added/removed on a reused
      // row.
      [self _syncExprEditorForLane:lane afterRow:existing];
      // Re-sync a KEPT editor's text to the (possibly undone/redone)
      // expression, so cmd-Z reaches the inline editor - the GLSL code row does
      // this via applyLane, but the expression editor is popover-level.
      [self _resyncExprEditorTextForLane:lane];
      continue;
    }
    _KKStaticValueRow *row = [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
    [self _installExprEditorForLane:lane];
  }
  // Order the stack by the canonical `lanes` order (the parameter order), not
  // alphabetically: a row restored by cmd-Z (undo of "move to animated") must
  // land back in its original parameter slot, not get sorted by label. `lanes`
  // arrives in paramOrder (see _unoptedLanes), so just place each present row
  // in that sequence.
  NSInteger pos = 0;
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *row = _rowsByLabel[lane.label];
    if (!row)
      continue;
    [_stack removeArrangedSubview:row];
    [_stack insertArrangedSubview:row atIndex:pos++];
    // Keep the inline expression editor directly under its row.
    NSView *ed = _exprRowsByLabel[lane.label];
    if (ed) {
      [_stack removeArrangedSubview:ed];
      [_stack insertArrangedSubview:ed atIndex:pos++];
    }
  }

  // Refresh each row's template default (drives the reset button) so a changed
  // default - e.g. a shader `// #color default=` edit - re-evaluates the reset
  // affordance on the reused rows. Mirrors rebuildRowsWithLanes:.
  if (_defaultsProvider)
    for (NSString *label in _rowsByLabel)
      _rowsByLabel[label].defaultValues = _defaultsProvider(label);

  // Rebuild the category nav so a tab disappears the moment its last constant
  // lane is moved to animated (and the selection falls back to a populated
  // tab).
  _rowCategoryByLabel = KKLaneCategoryByLabel(lanes);
  [self _rebuildCategoryNavForLanes:lanes initialCategory:_selectedCategory];
  [self _applyCategoryFilter];

  if (lanes.count == 0 && _popover)
    [_popover close];
  else if (_popover)
    [self _applyContentSize];

  // The shared mini-viewer renderer was updated externally (cmd-Z, or a new
  // layer's lanes arriving while the companion layer-list panel is open), but
  // the synthesized timeline setter doesn't repaint this open popover's
  // mini-viewer. Repaint the preview + handles so an Opt-peek reflects the new
  // lane set without a close/reopen - mirrors -_makeRowForLane:'s onValue path.
  [_miniViewer setNeedsDisplay:YES];
  [_miniViewer setHandlesNeedDisplay];
}

@end
