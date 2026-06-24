/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneCategoryNav.h"
#import "KKLocalized.h"
#import "KKMiniViewerView.h"
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
  // Excluded ("Animate" placeholder) rows aren't in _rowsByLabel; track them so
  // the category filter can hide/show them too.
  NSMutableDictionary<NSString *, NSView *> *_excludedRowsByLabel;
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
  void (^_onGradientTypeChanged)(NSString *, NSInteger);
  BOOL _editsKeypose;
  void (^_onDragBegin)(void);
  void (^_onDragEnd)(void);
  NSButton *_navPrevButton;
  NSButton *_navNextButton;
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
           [lane.categoryKey isEqualToString:sel]))
        page += [_KKStaticValueRow heightForLane:lane];
    rows = page + kKKCategoryPillH + KKPaddingMD;
  } else {
    for (KKLane *lane in lanes)
      if ([condVisible containsObject:lane.label])
        rows += [_KKStaticValueRow heightForLane:lane];
  }
  CGFloat h = KKPaddingMD + rows + KKPaddingMD;
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

  NSLayoutXAxisAnchor *titleLead = self.leadingAnchor;
  CGFloat titleLeadInset = KKPaddingMD;
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
      [_navPrevButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                   constant:KKPaddingMD],
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
  [self addSubview:_stack];
  [NSLayoutConstraint activateConstraints:@[
    [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
  ]];
  // Builds the category pill (when >1 category) and the stack's top constraint.
  [self _rebuildCategoryNavForLanes:lanes initialCategory:initialCategory];

  _lanes = [lanes copy];
  [self _seedCurrentValues];
  _labelColumnWidth = [_KKStaticValueRow labelColumnWidthForLanes:lanes];
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *row = [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
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
  _stackTopConstraint = [_stack.topAnchor constraintEqualToAnchor:top
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
}

// Resize the popover to hug the currently selected category's page so an
// uneven split (e.g. 1 Core row vs 3 Noise rows) doesn't leave empty space on
// the shorter page, and so revealing/hiding a conditional lane re-fits. No-op
// when there's no popover.
- (void)_resizePopoverToSelectedCategory {
  if (!_popover)
    return;
  _popover.contentSize = NSMakeSize(
      [_KKStaticValuesPopoverView _popoverWidthForDescriptor:_descriptorPath],
      [_KKStaticValuesPopoverView _heightForLanes:_lanes
                                   descriptorPath:_descriptorPath
                                       clipAspect:_clipAspect
                                    reserveHeader:_hasHeader
                                 selectedCategory:_selectedCategory
                                    valuesByLabel:_currentValuesByLabel]);
}

// While a colour swatch's shared panel is open, the panel is a separate window;
// the presenter's outside-click monitors would dismiss the popover on the first
// click into it (losing the row before the colour commits). Flag it so those
// monitors skip dismissal (see -suppressesPopoverDismiss); cleared when the
// panel closes.
- (void)_setColorEditing:(BOOL)editing {
  _colorPanelOpen = editing;
}

// Presenter hook (KKTimelineLanesView+Popovers `_showPopoverWithContent`): when
// YES, the outside-click / scroll dismissal monitors treat every event as
// inside the popover, so a colour-panel interaction can't close it.
- (BOOL)suppressesPopoverDismiss {
  return _colorPanelOpen;
}

- (_KKStaticValueRow *)_makeRowForLane:(KKLane *)lane {
  BOOL showsRemove = (_rowRemoveHandler != nil);
  // Non-animatable lanes are value-only: no "make animatable" gutter button.
  BOOL showsAdd = (_rowAddToAnimatedHandler != nil && lane.animatable);
  BOOL showsSmooth = (lane.spatialCurvable && _editsKeypose);
  _KKStaticValueRow *row =
      [[_KKStaticValueRow alloc] initWithLane:lane
                                  showsRemove:showsRemove
                           showsAddToAnimated:showsAdd
                                  showsSmooth:showsSmooth
                             labelColumnWidth:_labelColumnWidth];
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
    row.componentScale = ^double(NSInteger i) {
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
    if (s->_onHandleValue)
      s->_onHandleValue(label, values);
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
  if (lane.valueType == KKLaneValueTypeColor ||
      lane.valueType == KKLaneValueTypeGradient)
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
  return row;
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

    _KKExcludedRow *row =
        [[_KKExcludedRow alloc] initWithLabel:label
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
  for (NSView *v in [_stack.arrangedSubviews copy]) {
    [_stack removeArrangedSubview:v];
    [v removeFromSuperview];
  }
  [_rowsByLabel removeAllObjects];
  [_excludedRowsByLabel removeAllObjects];
  _lanes = [lanes copy];
  [self _seedCurrentValues];
  _labelColumnWidth = [_KKStaticValueRow labelColumnWidthForLanes:lanes];
  NSMutableDictionary<NSString *, NSString *> *catByLabel =
      [NSMutableDictionary dictionary];
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *row = [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
    if (lane.categoryKey.length)
      catByLabel[lane.label] = lane.categoryKey;
  }
  _rowCategoryByLabel = catByLabel;
  if (_defaultsProvider)
    for (NSString *label in _rowsByLabel)
      _rowsByLabel[label].defaultValues = _defaultsProvider(label);
  // Rebuild the category nav too (not just the rows): a re-target to a different
  // layer can change the whole category SET (e.g. a Core/Points layer -> a
  // Stroke layer), so the pills must follow - otherwise the old tabs persist and
  // the category filter hides every row of the new layer. Re-resolves
  // _selectedCategory to a surviving tab. Mirrors updateUnoptedLanes (constants).
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
  NSView *v = [_rowsByLabel[label] guideSliderView];
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

- (NSRect)guideFieldScreenRectForLabel:(NSString *)label
                             component:(NSInteger)component {
  NSView *f = [_rowsByLabel[label] guideFieldViewForComponent:component];
  NSWindow *w = f.window;
  if (!f || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[f convertRect:f.bounds toView:nil]];
}

- (void)setGuideFieldEditHandlerForLabel:(NSString *)label
                                 handler:(void (^)(NSInteger, double))handler {
  _rowsByLabel[label].onGuideFieldEdit = handler;
}

- (void)guideCommitFieldForLabel:(NSString *)label
                       component:(NSInteger)component {
  [_rowsByLabel[label] guideCommitFieldForComponent:component];
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
  }

  _lanes = [lanes copy];
  [self _seedCurrentValues];
  _labelColumnWidth = [_KKStaticValueRow labelColumnWidthForLanes:lanes];
  // Make a row for each newly-constant lane (append for now) and refresh the
  // existing ones.
  for (KKLane *lane in lanes) {
    if (_rowsByLabel[lane.label]) {
      [_rowsByLabel[lane.label] applyLane:lane]; // reflect external edits
      continue;
    }
    _KKStaticValueRow *row = [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
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
  }

  // Rebuild the category nav so a tab disappears the moment its last constant
  // lane is moved to animated (and the selection falls back to a populated
  // tab).
  _rowCategoryByLabel = KKLaneCategoryByLabel(lanes);
  [self _rebuildCategoryNavForLanes:lanes initialCategory:_selectedCategory];
  [self _applyCategoryFilter];

  if (lanes.count == 0 && _popover)
    [_popover close];
  else if (_popover)
    _popover.contentSize = NSMakeSize(
        [_KKStaticValuesPopoverView _popoverWidthForDescriptor:_descriptorPath],
        [_KKStaticValuesPopoverView heightForLanes:lanes
                                    descriptorPath:_descriptorPath
                                        clipAspect:_clipAspect
                                     reserveHeader:_hasHeader
                                  selectedCategory:_selectedCategory]);

  // The shared mini-viewer renderer was updated externally (cmd-Z, or a new
  // layer's lanes arriving while the companion layer-list panel is open), but
  // the synthesized timeline setter doesn't repaint this open popover's
  // mini-viewer. Repaint the preview + handles so an Opt-peek reflects the new
  // lane set without a close/reopen - mirrors -_makeRowForLane:'s onValue path.
  [_miniViewer setNeedsDisplay:YES];
  [_miniViewer setHandlesNeedDisplay];
}

@end
