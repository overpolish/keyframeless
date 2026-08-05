/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeEditorView.h"
#import "KKFloatingPanel.h"
#import "KKGLSLSyntax.h" // KKExprCatalog for the function reference menu
#import "KKLaneCategoryNav.h"
#import "KKLinkBus.h"
#import "KKLinkExpr.h"
#import "KKLocalized.h"
#import "KKLog.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView.h"
#import "KKPaddedScrollView.h"
#import "KKPaletteGenerator.h"
#import "KKPillBar.h"
#import "KKPillToggleRowView.h"
#import "KKPopoverHeaderView.h"
#import "KKPopoverKeepAlive.h"
#import "KKSliderView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTimelineStaticValuesPopover_Private.h" // @package ivars for categories
#import "KKTimingEvaluation.h" // KKTimelineLaneValueAtFraction (live ref override)
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
const CGFloat kKKExprEditorTextH = 30.0;
const CGFloat kKKExprEditorRowH = 46.0;       // text + result strip
const CGFloat kKKExprEditorExpandedH = 112.0; // ~3 lines + result strip

// A lane shows an inline expression editor when it carries a linkExpression AND
// is referenceable (not a code editor or a palette-generator bar - mirrors the
// manifest / row-label filter).
BOOL KKLaneHasExpressionEditor(KKLane *lane) {
  // Present = the lane HAS an expression binding, even an empty one. Clearing
  // the editor text leaves an empty (passthrough) expression, and the editor
  // stays open; only "Remove Expression" (which nils linkExpression) closes it.
  return lane.linkExpression != nil && lane.valueType != KKLaneValueTypeCode &&
         !lane.paletteGeneratorBar && !lane.positionPathDriven;
}

// Vertical breathing room kept around the popover when its natural height is
// clamped to the screen (so the arrow + a small gap fit on a low-res display),
// and the floor below which we never clamp.
static const CGFloat kKKStaticPopoverScreenMargin = 48.0;
static const CGFloat kKKStaticPopoverMinHeight = 160.0;

@implementation _KKStaticValuesPopoverView

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

- (void)
    reconfigureForEditsKeypose:(BOOL)editsKeypose
                     withLanes:(NSArray<KKLane *> *)lanes
                excludedLabels:(NSArray<NSString *> *)excludedLabels
                   headerTitle:(NSString *)headerTitle
                  headerDetail:(NSString *)headerDetail
                    headerIcon:(NSImage *)headerIcon
                    renderMode:(KKMiniViewerRenderMode)renderMode
                 onModeChanged:(void (^)(KKMiniViewerRenderMode))onModeChanged
                 onHandleValue:(void (^)(NSString *,
                                         NSArray<NSNumber *> *))onHandleValue
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

  // Render-mode gating follows the mode: the off/film/onion pill and the
  // filmstrip/onion layouts belong to keypose editing only. A keypose-born
  // popover switched to constants drops the pill and falls back to the single
  // frame; a constants-born popover switched to keypose gains the pill it
  // never built at init.
  BOOL wantPill =
      editsKeypose && onModeChanged != nil && _descriptorPath.length > 0;
  if (wantPill) {
    [self _installRenderModePill:renderMode onModeChanged:onModeChanged];
    _renderModePill.hidden = _compactMode;
  } else if (_renderModePill) {
    [_renderModePill removeFromSuperview];
    _renderModePill = nil;
  }
  if (_miniViewer)
    _miniViewer.renderMode = (NSInteger)renderMode;

  // Add the keypose nav chevrons (keypose mode) or remove them (constants
  // mode), then rebuild the header pinned after them. Same band geometry as
  // -initWithLanes:; the mini-viewer sits below the band and is unaffected.
  CGFloat bandH = [_KKStaticValuesPopoverView _renderModePillHeaderHeight];
  CGFloat bandCenterOffset = KKPaddingMD + bandH / 2.0;
  // Close + composition peek are preserved from init; nav + header follow.
  NSLayoutXAxisAnchor *bandLead =
      _compactButton
          ? _compactButton.trailingAnchor
          : (_rightPanelButton ? _rightPanelButton.trailingAnchor
                               : (_sidebarButton ? _sidebarButton.trailingAnchor
                                                 : self.leadingAnchor));
  CGFloat bandLeadInset = _sidebarButton ? KKSpacingMD : KKPaddingMD;
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
    _KKStaticValueRow *row = _rowsByLabel[lane.key];
    if (!row || lane.keyposes.count == 0)
      continue;
    [row applyValues:lane.keyposes.firstObject.values];
    if (lane.spatialCurvable)
      [row applySmooth:lane.keyposes.firstObject.spatialSmooth];
    if (lane.aspectLinkable)
      [row applyLink:lane.aspectLinked];
  }
}

+ (CGFloat)_popoverWidthForDescriptor:(NSString *)descriptorPath {
  return descriptorPath.length > 0 ? kCanvasPopoverW : kPopoverW;
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
      KKConditionalVisibleLaneKeys(lanes, valuesByLabel);
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
      if ([condVisible containsObject:lane.key] &&
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
      if ([condVisible containsObject:lane.key]) {
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

- (NSView *)panelDragHandleView {
  return _panelDragHandle;
}

- (NSSize)minimumHostedContentSize {
  if (_compactMode)
    return NSMakeSize(375.0, 175.0);
  return NSMakeSize(375.0, _descriptorPath.length > 0 ? 240.0 : 160.0);
}

// Current intrinsic height of the visible parameter stack. Hidden category /
// conditional rows collapse completely. Reading the arranged views directly
// also includes supplementary expression rows, which the lane model alone
// cannot describe accurately after an expand/collapse.
- (CGFloat)_visibleRowsNaturalHeight {
  CGFloat height = 0.0;
  for (NSView *view in _stack.arrangedSubviews) {
    if (view.hidden)
      continue;
    CGFloat h = view.intrinsicContentSize.height;
    if (h == NSViewNoIntrinsicMetric || h < 0.0)
      h = view.fittingSize.height;
    height += MAX(0.0, h);
  }
  return height;
}

// Reflow a freely-sized persistent panel. The viewport itself always fills
// the available width; KKMiniViewerView aspect-fits the media inside it and
// uses the remaining canvas for pan / zoom. Normal parameter pages hug their
// real row height and donate spare room to the viewer. A code page does the
// reverse: its editor expands to the bottom so only the editor's own text
// scroller is active, rather than nesting it inside a second tall scroller.
- (void)applyHostedContentSize:(NSSize)size {
  if (size.width <= 0.0 || size.height <= 0.0)
    return;
  _hostedContentSize = size;
  [self _applyMaxWidthCeiling];
  CGFloat contentWidth = size.width;
  _categoryPillBar.maxIntrinsicWidth =
      MAX(1.0, contentWidth - 2.0 * KKPaddingMD);
  for (NSString *label in _rowsByLabel)
    [_rowsByLabel[label] updateContentWidth:contentWidth];

  if (_miniViewerHeightConstraint) {
    // Reset a previously stretched code row before measuring this pass.
    _KKStaticValueRow *visibleCodeRow = nil;
    CGFloat codeBaseHeight = 0.0;
    for (KKLane *lane in _lanes) {
      _KKStaticValueRow *row = _rowsByLabel[lane.key];
      if (lane.valueType != KKLaneValueTypeCode || !row || row.hidden)
        continue;
      CGFloat base = [_KKStaticValueRow heightForLane:lane
                                         contentWidth:contentWidth
                                     labelColumnWidth:_labelColumnWidth];
      [row setEditorRowHeight:base];
      if (!visibleCodeRow) {
        visibleCodeRow = row;
        codeBaseHeight = base;
      }
    }

    CGFloat rowsH = [self _visibleRowsNaturalHeight];
    CGFloat topH =
        _hasHeader
            ? KKPaddingMD +
                  [_KKStaticValuesPopoverView _renderModePillHeaderHeight] +
                  KKPaddingMD
            : KKPaddingMD;
    CGFloat categoryH = _categoryPillBar ? kKKCategoryPillH + KKPaddingMD : 0.0;
    CGFloat betweenH =
        _accessoryTopConstraint.constant + _accessoryHeight + categoryH;
    CGFloat sharedH = MAX(0.0, size.height - topH - betweenH);
    if (_compactMode) {
      // With the mini viewer hidden, the rows viewport owns all remaining
      // space. A code page must therefore stretch its editor through that
      // viewport; retaining the expanded-mode 150pt cap leaves a dead region
      // below the editor and creates an unnecessary second scrolling area.
      if (visibleCodeRow) {
        CGFloat otherRowsH = MAX(0.0, rowsH - codeBaseHeight);
        [visibleCodeRow setEditorRowHeight:MAX(100.0, sharedH - otherRowsH)];
      }
      _miniViewerHeightConstraint.constant = 0.0;
      [self setNeedsLayout:YES];
      [self layoutSubtreeIfNeeded];
      return;
    }
    // The viewer is the primary editor surface. Ordinary parameter pages may
    // use at most 40% of the shared height (viewer gets at least 60%). A code
    // page deliberately starts 50/50 so viewer and editor grow equally until
    // the editor reaches its cap below.
    CGFloat maxRowsViewportH = floor(sharedH * (visibleCodeRow ? 0.5 : 0.4));
    if (visibleCodeRow) {
      CGFloat otherRowsH = MAX(0.0, rowsH - codeBaseHeight);
      // Viewer and code grow together until the editor reaches 250pt. From
      // there every additional point belongs to the viewer. The 200pt floor is
      // the last usable text area; below that the outer rows scroller is the
      // fallback instead of crushing the editor chrome.
      CGFloat codeH = MIN(250.0, MAX(200.0, maxRowsViewportH - otherRowsH));
      [visibleCodeRow setEditorRowHeight:codeH];
      rowsH = otherRowsH + codeH;
    }
    // When the panel is too short, the rows viewport shrinks and its outer
    // scroller becomes the overflow fallback. Otherwise it exactly hugs the
    // rows, leaving every spare point to the mini viewer.
    CGFloat rowsViewportH = MIN(rowsH, MAX(0.0, maxRowsViewportH));
    _miniViewerHeightConstraint.constant = MAX(1.0, sharedH - rowsViewportH);
  }
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
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

- (KKPopoverPeekButton *)_makeCompositionPeekButton {
  __weak typeof(self) weak = self;
  return KKCreateCompositionPeekButton(^(BOOL held) {
    __strong typeof(weak) self = weak;
    if (self.onCompositionPeekChanged)
      self.onCompositionPeekChanged(held);
  });
}

- (KKPopoverSidebarButton *)_makeSidebarButton {
  __weak typeof(self) weak = self;
  return KKCreateSidebarVisibilityButton(YES, ^(BOOL visible) {
    __strong typeof(weak) self = weak;
    if (self.onSidebarVisibilityChanged)
      self.onSidebarVisibilityChanged(visible);
  });
}

- (void)setSidebarVisible:(BOOL)visible {
  _sidebarButton.sidebarVisible = visible;
}

- (KKPopoverSidebarButton *)_makeRightPanelButton {
  __weak typeof(self) weak = self;
  return KKCreateRightPanelVisibilityButton(YES, ^(BOOL visible) {
    __strong typeof(weak) self = weak;
    if (self.onRightPanelVisibilityChanged)
      self.onRightPanelVisibilityChanged(visible);
  });
}

- (void)setRightPanelVisible:(BOOL)visible {
  _rightPanelButton.sidebarVisible = visible;
}

- (void)setRightPanelToggleVisible:(BOOL)visible {
  if (!_rightPanelButton)
    return;
  _rightPanelButton.hidden = !visible;
  _rightPanelLeadingConstraint.constant = visible ? KKPaddingSM : 0.0;
  _rightPanelWidthConstraint.constant =
      visible ? [_KKStaticValuesPopoverView _renderModePillHeaderHeight] : 0.0;
}

- (NSButton *)_makeCompactButton {
  NSString *label = KKLoc(@"Use compact editor",
                          @"Accessibility label for hiding the mini viewer in "
                           "the constants/keypose editor.");
  NSImage *image =
      [NSImage imageWithSystemSymbolName:@"rectangle.compress.vertical"
                accessibilityDescription:label];
  NSButton *button = [NSButton buttonWithImage:image ?: [NSImage new]
                                        target:self
                                        action:@selector(_compactClicked:)];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  button.bordered = NO;
  button.bezelStyle = NSBezelStyleShadowlessSquare;
  button.imageScaling = NSImageScaleProportionallyDown;
  button.accessibilityLabel = label;
  button.toolTip = KKLoc(@"Hide or show the mini viewer. (V)",
                         @"Tooltip for the compact editor toggle.");
  [button.cell sendActionOn:NSEventMaskLeftMouseDown];
  return button;
}

- (void)_compactClicked:(id)sender {
  BOOL compact = !_compactMode;
  if (self.onCompactModeChanged)
    self.onCompactModeChanged(compact);
  else
    [self setCompactMode:compact];
}

- (void)setCompactMode:(BOOL)compact {
  _compactMode = compact;
  _miniViewer.activitySuspended = compact;
  _compactButton.state =
      compact ? NSControlStateValueOn : NSControlStateValueOff;
  _compactButton.contentTintColor = compact ? NSColor.accentMatchingHost : nil;
  _miniViewerScroll.hidden = compact;
  _renderModePill.hidden = compact;
  if (_miniViewerHeightConstraint)
    _miniViewerHeightConstraint.constant = compact ? 0.0 : 1.0;
  // In compact mode the zero-height viewer already begins one standard gap
  // below the title bar. Do not add the viewer-to-accessory gap a second time.
  if (_accessoryTopConstraint)
    _accessoryTopConstraint.constant =
        compact ? 0.0
                : (_accessoryHost.subviews.count
                       ? _accessoryTopInset - [self _accessoryInstalledTopDrop]
                       : _accessoryTopInset);
  [self applyHostedContentSize:_hostedContentSize];
}

- (NSSize)naturalHostedContentSize {
  return [self _naturalContentSize];
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

// Build + constrain the trailing render-mode pill (off/film/onion).
// Shared by init and -reconfigureForEditsKeypose:...: a constants-born popover
// has no pill until an in-place switch to keypose mode installs one. No-op if
// already installed.
- (void)_installRenderModePill:(KKMiniViewerRenderMode)renderMode
                 onModeChanged:(void (^)(KKMiniViewerRenderMode))onModeChanged {
  if (_renderModePill)
    return;
  CGFloat bandH = [_KKStaticValuesPopoverView _renderModePillHeaderHeight];
  CGFloat bandCenterOffset = KKPaddingMD + bandH / 2.0;
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
  [NSLayoutConstraint activateConstraints:@[
    [pill.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                        constant:-KKPaddingMD],
    [pill.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                       constant:bandCenterOffset],
    [pill.heightAnchor constraintEqualToConstant:bandH],
  ]];
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
        showsRightPanelToggle:(BOOL)showsRightPanelToggle
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
  // title; render-mode pill trailing. A transparent drag strip spans the whole
  // band behind those controls, so decorative and empty space moves the panel.
  CGFloat bandH = [_KKStaticValuesPopoverView _renderModePillHeaderHeight];
  CGFloat bandCenterOffset = KKPaddingMD + bandH / 2.0;
  BOOL hasNav = (showPill && onNavigate != nil);
  BOOL hasBand = (showPill || headerTitle.length > 0);

  if (hasBand) {
    _panelDragHandle = [[KKPanelDragHandleView alloc] initWithFrame:NSZeroRect];
    _panelDragHandle.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_panelDragHandle];
    [NSLayoutConstraint activateConstraints:@[
      [_panelDragHandle.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor],
      [_panelDragHandle.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor],
      [_panelDragHandle.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_panelDragHandle.heightAnchor
          constraintEqualToConstant:KKPaddingMD + bandH + KKPaddingMD],
    ]];
  }

  // Close then composition peek, leftmost in the band - always present (both
  // modes). Nav + header follow.
  NSLayoutXAxisAnchor *bandLead = self.leadingAnchor;
  CGFloat bandLeadInset = KKPaddingMD;
  if (hasBand) {
    _closeButton = [self _makeCloseButton];
    _compositionPeekButton = [self _makeCompositionPeekButton];
    _sidebarButton = [self _makeSidebarButton];
    if (showsRightPanelToggle)
      _rightPanelButton = [self _makeRightPanelButton];
    if (descriptorPath.length > 0)
      _compactButton = [self _makeCompactButton];
    [self addSubview:_closeButton];
    [self addSubview:_compositionPeekButton];
    [self addSubview:_sidebarButton];
    if (_rightPanelButton)
      [self addSubview:_rightPanelButton];
    if (_compactButton)
      [self addSubview:_compactButton];
    [NSLayoutConstraint activateConstraints:@[
      [_closeButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                 constant:KKPaddingMD],
      [_closeButton.centerYAnchor constraintEqualToAnchor:self.topAnchor
                                                 constant:bandCenterOffset],
      [_closeButton.widthAnchor constraintEqualToConstant:bandH],
      [_closeButton.heightAnchor constraintEqualToConstant:bandH],
      [_compositionPeekButton.leadingAnchor
          constraintEqualToAnchor:_closeButton.trailingAnchor
                         constant:KKPaddingSM],
      [_compositionPeekButton.centerYAnchor
          constraintEqualToAnchor:_closeButton.centerYAnchor],
      [_compositionPeekButton.widthAnchor constraintEqualToConstant:bandH],
      [_compositionPeekButton.heightAnchor constraintEqualToConstant:bandH],
      [_sidebarButton.leadingAnchor
          constraintEqualToAnchor:_compositionPeekButton.trailingAnchor
                         constant:KKPaddingSM],
      [_sidebarButton.centerYAnchor
          constraintEqualToAnchor:_compositionPeekButton.centerYAnchor],
      [_sidebarButton.widthAnchor constraintEqualToConstant:bandH],
      [_sidebarButton.heightAnchor constraintEqualToConstant:bandH],
    ]];
    if (_rightPanelButton) {
      _rightPanelLeadingConstraint = [_rightPanelButton.leadingAnchor
          constraintEqualToAnchor:_sidebarButton.trailingAnchor
                         constant:KKPaddingSM];
      _rightPanelWidthConstraint =
          [_rightPanelButton.widthAnchor constraintEqualToConstant:bandH];
      [NSLayoutConstraint activateConstraints:@[
        _rightPanelLeadingConstraint,
        [_rightPanelButton.centerYAnchor
            constraintEqualToAnchor:_sidebarButton.centerYAnchor],
        _rightPanelWidthConstraint,
        [_rightPanelButton.heightAnchor constraintEqualToConstant:bandH],
      ]];
    }
    if (_compactButton) {
      NSView *beforeCompact = _rightPanelButton ?: _sidebarButton;
      [NSLayoutConstraint activateConstraints:@[
        [_compactButton.leadingAnchor
            constraintEqualToAnchor:beforeCompact.trailingAnchor
                           constant:KKPaddingSM],
        [_compactButton.centerYAnchor
            constraintEqualToAnchor:_sidebarButton.centerYAnchor],
        [_compactButton.widthAnchor constraintEqualToConstant:bandH],
        [_compactButton.heightAnchor constraintEqualToConstant:bandH],
      ]];
    }
    bandLead = (_compactButton ?: _rightPanelButton ?: _sidebarButton)
                   .trailingAnchor;
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

  if (showPill)
    [self _installRenderModePill:renderMode onModeChanged:onModeChanged];

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
    _miniViewerScroll = sv;
    NSClipView *clip = sv.contentView;
    CGFloat initialCanvasWidth = W - 2.0 * KKPaddingMD;
    _miniViewerHeightConstraint = [sv.heightAnchor
        constraintEqualToConstant:initialCanvasWidth /
                                  (clipAspect > 0 ? clipAspect : 16.0 / 9.0)];
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

  // The host accessory strip sits between the mini-viewer band and everything
  // below it, IN the chain rather than over it: the category nav (and, with no
  // pill, the row scroller) pins below the host, and the host pins below the
  // mini-viewer. Empty and zero-height here, so a host that never installs one
  // gets the layout it had before this existed.
  _accessoryHost = [[NSView alloc] initWithFrame:NSZeroRect];
  _accessoryHost.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_accessoryHost];
  _accessoryHeightConstraint =
      [_accessoryHost.heightAnchor constraintEqualToConstant:0.0];
  _accessoryTopInset = stackTopInset;
  _accessoryTopConstraint =
      [_accessoryHost.topAnchor constraintEqualToAnchor:stackTopAnchor
                                               constant:stackTopInset];
  [NSLayoutConstraint activateConstraints:@[
    [_accessoryHost.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_accessoryHost.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    _accessoryTopConstraint,
    _accessoryHeightConstraint,
  ]];
  stackTopAnchor = _accessoryHost.bottomAnchor;
  stackTopInset = 0.0;

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
    _rowsByLabel[lane.key] = row;
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
// Re-assert the popover's width ceiling - and the category bar's matching
// intrinsic cap - for the current hosted width. Called from the nav rebuild
// (the initial build, before the panel exists) and from every hosted resize, so
// the ceiling follows the panel instead of pinning the editor to its first
// width.
//
// The ceiling exists because a single wide row - e.g. a 4-component lane whose
// auto-sized component labels are long - otherwise propagates its required
// width up through `row.width == stack.width` and NSPopover grows the whole
// popover past its hardcoded size, leaving the centred pill bar over the edge.
- (void)_applyMaxWidthCeiling {
  CGFloat maxW = _hostedContentSize.width > 0.0
                     ? _hostedContentSize.width
                     : [_KKStaticValuesPopoverView
                           _popoverWidthForDescriptor:_descriptorPath];
  if (!_maxWidthConstraint) {
    _maxWidthConstraint =
        [self.widthAnchor constraintLessThanOrEqualToConstant:maxW];
    _maxWidthConstraint.active = YES;
  } else if (fabs(_maxWidthConstraint.constant - maxW) > 0.5) {
    _maxWidthConstraint.constant = maxW;
  }
  _categoryPillBar.maxIntrinsicWidth = maxW - KKPaddingMD * 2;
}

- (void)_rebuildCategoryNavForLanes:(NSArray<KKLane *> *)lanes
                    initialCategory:(NSString *)requested {
  _categoryDefinitions = [KKOrderedLaneCategories(lanes) copy];
  [_categoryPillBar removeFromSuperview];
  _categoryPillBar = nil;
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
        // A source may have been renamed since these rows were built (the
        // shader's own name lives a category away), and switching category
        // only reveals rows - it doesn't rebuild them.
        [ss _retranslateExprEditors];
        [ss _applyCategoryFilter];
        [ss _resizePopoverToSelectedCategory];
        if (ss.onCategoryChanged)
          ss.onCategoryChanged(categoryKey);
      });
  if (pill) {
    _categoryKeys = KKLaneCategoryKeys(lanes);
    _selectedCategory = KKResolveLaneCategory(lanes, requested);
    _categoryPill = pill;
    // Wrapped in the same edge-faded horizontal scroll the lane-filter
    // checklist uses. Added bare, a long category run overflowed the popover
    // and the tabs past the edge were simply unreachable - and a shader can
    // name as many groups as it likes, so this isn't a rare case.
    KKPillBar *bar = [[KKPillBar alloc] initWithPillRow:pill];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    // Cap the intrinsic width at what this popover actually has. Reporting the
    // full pill run instead stretched the content VIEW past the popover's fixed
    // contentSize (540 -> 597 with 9 categories) while the WINDOW stayed 540,
    // so the bar overhung the edge until a reopen re-created the popover at the
    // inflated size. Capped, the inner scroll takes over as intended below.
    bar.maxIntrinsicWidth = [_KKStaticValuesPopoverView
                                _popoverWidthForDescriptor:_descriptorPath] -
                            KKPaddingMD * 2;
    // Hug the content while it fits, but near-zero compression resistance lets
    // it shrink so the inner scroll takes over instead of clipping.
    [bar setContentHuggingPriority:NSLayoutPriorityRequired - 1
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [bar setContentCompressionResistancePriority:1
                                  forOrientation:
                                      NSLayoutConstraintOrientationHorizontal];
    _categoryPillBar = bar;
    [self addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
      [bar.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [bar.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                                     constant:KKPaddingMD],
      [bar.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                   constant:-KKPaddingMD],
      [bar.topAnchor constraintEqualToAnchor:_categoryNavTopAnchor
                                    constant:_categoryNavTopInset],
      [bar.heightAnchor constraintEqualToConstant:kKKCategoryPillH],
    ]];
    top = bar.bottomAnchor;
    inset = KKPaddingMD;
  } else {
    _categoryKeys = nil;
    _selectedCategory = nil;
  }
  _stackTopConstraint = [_rowsScroll.topAnchor constraintEqualToAnchor:top
                                                              constant:inset];
  _stackTopConstraint.active = YES;
  // Idempotent; also covers the initial build, which runs before the popover
  // (and so before the first -_applyContentSize).
  [self _applyMaxWidthCeiling];
}

// (Re)seed the live per-lane values from the current `_lanes` snapshot, so the
// conditional-visibility cascade and page-resize start from the persisted
// values; live edits then overwrite single entries via the row's onValue.
- (void)_seedCurrentValues {
  _currentValuesByLabel =
      [NSMutableDictionary dictionaryWithCapacity:_lanes.count];
  _laneGatesVisibility = NO;
  for (KKLane *l in _lanes) {
    _currentValuesByLabel[l.key] = l.keyposes.firstObject.values ?: @[];
    if (l.visibleWhenKey.length || l.maxControllerKey.length)
      _laneGatesVisibility = YES;
  }
}

// Show only the rows in the selected category (uncategorised rows show under
// every category) that also pass their conditional `visibleWhen` rule. With no
// selected category (one category or none) every category-eligible row shows.
// NSStackView collapses hidden arranged subviews, so visible rows pack to top.
- (void)_applyCategoryFilter {
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneKeys(_lanes, _currentValuesByLabel);
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
// whose max tracks another lane (maxControllerKey, e.g. Mirage's colour count
// vs Type) needs its slider re-bounded whenever the controller changes. Runs on
// every visibility pass (which re-fires on any gating edit), so the max stays
// live.
- (void)_refreshDynamicMaxRows {
  for (KKLane *l in _lanes) {
    if (l.maxControllerKey.length == 0 ||
        l.componentMaxByControllerValue.count == 0)
      continue;
    _KKStaticValueRow *row = _rowsByLabel[l.key];
    if (!row)
      continue;
    KKLane *adjusted = [self _laneWithDynamicMaxApplied:l];
    double effMax = adjusted.componentMax.count
                        ? adjusted.componentMax[0].doubleValue
                        : 0.0;
    [row applySliderMax:effMax];
  }
}

- (CGFloat)_accessoryInstalledTopDrop {
  return MIN(_accessoryTopInset, KKPaddingMD);
}

- (void)setAccessoryView:(NSView *)view height:(CGFloat)height {
  for (NSView *v in _accessoryHost.subviews.copy)
    [v removeFromSuperview];
  _accessoryHeight = view ? MAX(0.0, height) : 0.0;
  _accessoryHeightConstraint.constant = _accessoryHeight;
  // An installed strip pads itself, so the ONE KKPaddingMD of separation the
  // chain would give it goes: kept, it stacked on the strip's own top inset and
  // the strip's content sat 12 above / 6 below. Only that one pad is dropped -
  // with no mini-viewer the inset also clears a header band, which still has to
  // be cleared. Restored with the strip, so a popover that never installs one
  // lays out exactly as before.
  _accessoryTopConstraint.constant =
      view ? _accessoryTopInset - [self _accessoryInstalledTopDrop]
           : _accessoryTopInset;
  if (view) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [_accessoryHost addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
      [view.leadingAnchor constraintEqualToAnchor:_accessoryHost.leadingAnchor],
      [view.trailingAnchor
          constraintEqualToAnchor:_accessoryHost.trailingAnchor],
      [view.topAnchor constraintEqualToAnchor:_accessoryHost.topAnchor],
      [view.bottomAnchor constraintEqualToAnchor:_accessoryHost.bottomAnchor],
    ]];
  }
  // No-op before the popover exists (the presenter's initial clamp reads the
  // new natural size); re-fits it afterwards.
  [self _applyContentSize];
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
  if (_compactMode && _descriptorPath.length > 0) {
    h -= [_KKStaticValuesPopoverView
             _canvasHeightForAspect:_clipAspect
                              width:[_KKStaticValuesPopoverView
                                        _popoverWidthForDescriptor:
                                            _descriptorPath]] +
         KKPaddingMD;
  }
  // The class-level height calc assumes every expression editor is COLLAPSED
  // (it has no instance state); add the extra height for each visible EXPANDED
  // one.
  CGFloat extra = kKKExprEditorExpandedH - kKKExprEditorRowH;
  for (NSString *label in _exprExpandedLabels) {
    NSView *ed = _exprRowsByLabel[label];
    if (ed && !ed.hidden)
      h += extra;
  }
  // Likewise instance state: the host strip is installed after init, so the
  // class-level calc knows nothing about it. It costs its own height and gives
  // back the external gap the install zeroes (see -setAccessoryView:height:),
  // which that calc counted as part of the mini-viewer band.
  if (_accessoryHeight > 0.0)
    h += _accessoryHeight - [self _accessoryInstalledTopDrop];
  return NSMakeSize(_hostedContentSize.width > 0.0
                        ? _hostedContentSize.width
                        : [_KKStaticValuesPopoverView
                              _popoverWidthForDescriptor:_descriptorPath],
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
  // Before the popover check: the ceiling must track the size class even on
  // the paths that run while the popover is still being built.
  [self _applyMaxWidthCeiling];
  if (!_popover && !_onRequestContentSize)
    return;
  CGSize s = [self _naturalContentSize];
  NSScreen *screen = self.window.screen;
  if (!screen)
    screen = _popover.contentViewController.view.window.screen;
  s.height = [self _clampHeight:s.height toScreen:screen];
  if (_onRequestContentSize)
    _onRequestContentSize(s);
  else
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
  if (!_popover && !_onRequestContentSize)
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
  return _colorPanelOpen || _exprMenuOpen;
}

// A lane whose slider max reacts to another lane (maxControllerKey): returns
// a copy with componentMax[0] swapped for the value looked up from the
// controller lane's current value, so the range tracks e.g. Mirage's Type.
// Unchanged lanes are returned as-is. Rebuilt whenever rows rebuild (Type
// change re-runs the visibility cascade), so the max stays reactive.
- (KKLane *)_laneWithDynamicMaxApplied:(KKLane *)lane {
  if (lane.maxControllerKey.length == 0 ||
      lane.componentMaxByControllerValue.count == 0)
    return lane;
  NSArray<NSNumber *> *cv = _currentValuesByLabel[lane.maxControllerKey];
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
  NSString *label = lane.key;
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
  // raw pixels (a raw px radius). Returns 0 until the feed resolves, which the
  // row treats as "fall back to raw norm".
  if (lane.componentsScaleWithMedia) {
    NSArray<NSString *> *units = lane.componentUnits;
    row.componentScale = ^double(NSInteger i) {
      // Per-component units decide scaling: ONLY a "px" component (or an
      // absent units array, the legacy scale-all default) scales with the
      // media. A "%" is a literal percentage, an EXPLICIT empty-string
      // component (units={px,px,,}) is a raw 0..1 value, and a plugin's own
      // unit ("°", "stops") is a label on a raw number - none of them are
      // pixels. Lets one lane mix px W/H with raw, % or labelled X/Y.
      if (i < (NSInteger)units.count && ![units[i] isEqualToString:@"px"])
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
    // Re-run every expression readout now (not just on the 0.2s timer) so a
    // lane deriving from THIS one (e.g. rotation = min(${...Split}, 90)) shows
    // its new result on the same drag tick, matching the mini-viewer preview.
    [s _updateAllExprResults];
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
  row.onCodeSaveNameChanged = ^(NSString *name) {
    __strong typeof(weak) s = weak;
    if (s.onHandleCodeSaveName)
      s.onHandleCodeSaveName(label, name);
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

    // Resolve the lane's display name (identity `label` here is the KEY, e.g.
    // a shader uniform name) so the excluded row reads the same name as the
    // editable row it replaced.
    NSString *displayLabel = nil;
    for (KKLane *l in _lanes)
      if ([l.key isEqualToString:label]) {
        displayLabel = l.label;
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
    _KKStaticValueRow *reused = keepCode[lane.key];
    _KKStaticValueRow *row = reused ?: [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    if (!reused) // a reused row already has its stack-width constraint
      [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.key] = row;
    [self _installExprEditorForLane:lane];
    if (lane.categoryKey.length)
      catByLabel[lane.key] = lane.categoryKey;
  }
  // Tear down any PRESERVED code row the new lane set didn't reuse (e.g. the
  // constants "Mirage" code lane when reconfiguring into a keypose popover,
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
  [self _refreshDynamicMaxRows];
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
  // Rows are keyed by lane.key - the survivors set MUST be keys too, or every
  // row whose key differs from its display label (all Mirage directives) is
  // torn down and remade on each update, stealing focus from an open editor.
  NSSet<NSString *> *newSet =
      [NSSet setWithArray:[lanes valueForKeyPath:@"key"]];

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
    _KKStaticValueRow *existing = _rowsByLabel[lane.key];
    // A reused row whose rendering STRUCTURE changed (palette bar <-> value
    // editor, code <-> non-code, seed <-> field, float <-> percent/choice, unit
    // or field-count change) can't be updated in place - drop it so it is
    // remade below. Metadata-only changes (range, values) are handled by
    // applyLane; a shared label-column shift (a relabel changed the widest
    // name) restretches in place below - remaking for it tore down the CODE
    // editor mid-typing when its own rename widened the column (focus +
    // scroll lost on every debounce commit).
    if (existing && ![existing renderShapeMatchesLane:lane]) {
      [_stack removeArrangedSubview:existing];
      [existing removeFromSuperview];
      [_rowsByLabel removeObjectForKey:lane.key];
      // Drop its inline expression editor too (a remake reinstalls a fresh
      // one).
      NSView *oldEd = _exprRowsByLabel[lane.key];
      if (oldEd) {
        [_stack removeArrangedSubview:oldEd];
        [oldEd removeFromSuperview];
        [_exprRowsByLabel removeObjectForKey:lane.key];
        [_exprEditorByLabel removeObjectForKey:lane.key];
      }
      existing = nil;
    }
    if (existing) {
      [existing updateLabelColumnWidth:_labelColumnWidth];
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
    _rowsByLabel[lane.key] = row;
    [self _installExprEditorForLane:lane];
  }
  // Order the stack by the canonical `lanes` order (the parameter order), not
  // alphabetically: a row restored by cmd-Z (undo of "move to animated") must
  // land back in its original parameter slot, not get sorted by label. `lanes`
  // arrives in paramOrder (see _unoptedLanes), so just place each present row
  // in that sequence.
  NSInteger pos = 0;
  for (KKLane *lane in lanes) {
    _KKStaticValueRow *row = _rowsByLabel[lane.key];
    if (!row)
      continue;
    [_stack removeArrangedSubview:row];
    [_stack insertArrangedSubview:row atIndex:pos++];
    // Keep the inline expression editor directly under its row.
    NSView *ed = _exprRowsByLabel[lane.key];
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

  // Rebuild only when the category run itself changed. A normal value write
  // refreshes the constants lanes too; tearing down the unchanged pill bar in
  // the middle of its row's slider drag invalidates that tracking control and
  // can make the freshly-built bar fall back to its first page ("Shader").
  // Structural changes still rebuild immediately so an emptied category
  // disappears as before.
  _rowCategoryByLabel = KKLaneCategoryByLabel(lanes);
  NSArray<NSArray<NSString *> *> *categoryDefinitions =
      KKOrderedLaneCategories(lanes);
  if (![_categoryDefinitions isEqualToArray:categoryDefinitions])
    [self _rebuildCategoryNavForLanes:lanes
                      initialCategory:_selectedCategory];
  [self _applyCategoryFilter];

  // No rows left = nothing to edit = close... unless a host accessory strip is
  // installed, which is content of its own AND the only way back: Mirage's
  // shader rack scopes these rows to the link selected IN the strip, so a
  // scope that momentarily resolves to nothing (a just-appended entry whose
  // lanes have not been derived yet) would dismiss the popover the user is
  // building the chain in, with no way to reselect.
  BOOL hosted = _popover || _onRequestContentSize;
  if (lanes.count == 0 && hosted && _accessoryHeight <= 0.0) {
    if (_onRequestClose)
      _onRequestClose();
    else
      [_popover close];
  } else if (hosted) {
    if (lanes.count == 0)
      KKLogDebug(@"[StaticValues] no constant rows, accessory installed - "
                 @"holding the popover open");
    [self _applyContentSize];
  }

  // The shared mini-viewer renderer was updated externally (cmd-Z, or a new
  // layer's lanes arriving while the companion layer-list panel is open), but
  // the synthesized timeline setter doesn't repaint this open popover's
  // mini-viewer. Repaint the preview + handles so an Opt-peek reflects the new
  // lane set without a close/reopen - mirrors -_makeRowForLane:'s onValue path.
  [_miniViewer setNeedsDisplay:YES];
  [_miniViewer setHandlesNeedDisplay];
}

@end
