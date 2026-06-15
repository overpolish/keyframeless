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
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKShape.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

// Build-time helpers (implemented in the primary @implementation below).
@interface CanvasLayerListView ()
- (NSTextField *)_buildTitleLabel;
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

  [NSLayoutConstraint activateConstraints:@[
    [title.topAnchor constraintEqualToAnchor:self.topAnchor constant:pad],
    [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:pad],

    [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor
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
- (void)reloadFromParam {
  // Skip the echo of our own write (the host may not have committed it yet, so
  // re-reading here would wipe the just-made edit). Only external changes
  // (undo/redo) fall through to an actual refresh.
  if (_selfWritePending > 0) {
    _selfWritePending--;
    return;
  }
  [self _commitRenameIfEditing];
  _paths = [self _readPaths];
  // Drop selection indices that no longer exist (undo may have removed rows).
  NSMutableIndexSet *valid = [NSMutableIndexSet indexSet];
  [_selection enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    if (i < _paths.count)
      [valid addIndex:i];
  }];
  [_selection removeAllIndexes];
  [_selection addIndexes:valid];
  [self _rebuildRows];
}

#pragma mark - Layer blob IO (KKBezierPath <-> kParamLayerData string)

- (NSMutableArray<KKBezierPath *> *)_readPaths {
  id<PROAPIAccessing> api = self.apiManager;
  if (!api)
    return [NSMutableArray array];
  return CanvasReadLayerPaths(api, self.paramActionTarget ?: self);
}

- (void)_writePaths:(NSArray<KKBezierPath *> *)paths {
  id<PROAPIAccessing> api = self.apiManager;
  if (!api)
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return;
  id target = self.paramActionTarget ?: self;
  [action startAction:target];
  id<FxParameterSettingAPI_v5> setAPI =
      [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  _selfWritePending++; // skip the echo this write will trigger
  KKWriteCustomParamString(setAPI, [blob base64EncodedStringWithOptions:0],
                           kParamLayerData);
  [action endAction:target];
}

// Mutate the cached paths, persist once, rebuild rows from the cache (no
// re-read, thumbnails reused). The new model's equivalent of the old store's
// `_modifyPaths:` (no store / param-sync / OSC pump).
- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *paths))block {
  block(_paths);
  [self _writePaths:_paths];
  [self _rebuildRows];
}

- (nullable KKBezierPath *)_imageLayerForURL:(NSURL *)url {
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:url.path];
  if (!img || img.size.width <= 0 || img.size.height <= 0)
    return nil;
  float aspect = (float)(img.size.width / img.size.height);

  const float cw = 1920.0f, ch = 1080.0f;
  float scale = fminf((cw * 0.5f) / (float)img.size.width,
                      (ch * 0.5f) / (float)img.size.height);
  float w = (float)img.size.width * scale / cw;
  float h = (float)img.size.height * scale / ch;
  float x0 = 0.5f - w / 2.0f, y0 = 0.5f - h / 2.0f;

  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.isImage = YES;
  p.imagePath = url.path;
  p.imageAspect = aspect;
  p.name = url.lastPathComponent.stringByDeletingPathExtension;
  p.strokeEnabled = NO;
  p.fillEnabled = NO;
  KKRectShape *rect = [[KKRectShape alloc] init];
  rect.min = simd_make_float2(x0, y0);
  rect.max = simd_make_float2(x0 + w, y0 + h);
  p.shape = rect;
  return p;
}

- (nullable NSImage *)_thumbnailForPath:(NSString *)imagePath {
  if (!imagePath.length)
    return nil;
  NSImage *cached = _thumbCache[imagePath];
  if (cached)
    return cached;
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:imagePath];
  if (img)
    _thumbCache[imagePath] = img;
  return img;
}

#pragma mark - Per-row actions

- (void)beginRenameAtIndex:(NSUInteger)idx {
  [self _beginRenameAtIndex:idx];
}

- (void)commitRenameIfEditing {
  [self _commitRenameIfEditing];
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
    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 if (idx < paths.count)
                                   [paths removeObjectAtIndex:idx];
                               }];
    [self->_selection removeAllIndexes];
  }];
}

#pragma mark - Context menu actions

- (void)renameRow:(NSMenuItem *)sender {
  [self _beginRenameAtIndex:(NSUInteger)sender.tag];
}

- (void)_beginRenameAtIndex:(NSUInteger)idx {
  if (idx >= _paths.count)
    return;
  if (_editingIndex >= 0 && _editingIndex != (NSInteger)idx)
    [self _commitRenameIfEditing];
  _editingIndex = (NSInteger)idx;
  [self _rebuildRows];
  // Become key + focus the field on the next tick (after the rebuild lands).
  NSTextField *field = _editingField;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.window makeKeyWindow];
    [self.window makeFirstResponder:field];
    [field selectText:nil];
    // Now that focus is established, listen for the real end-of-edit.
    field.delegate = self;
  });
}

- (void)_commitRename {
  NSInteger idx = _editingIndex;
  NSTextField *field = _editingField;
  _editingIndex = -1;
  _editingField = nil;
  if (idx < 0 || (NSUInteger)idx >= _paths.count) {
    [self _rebuildRows];
    [self _resetCursorAfterEditing];
    return;
  }
  NSString *newName = [field.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if ((NSUInteger)idx < paths.count && newName.length)
      paths[idx].name = newName;
  }];
  [self _resetCursorAfterEditing];
}

// The field editor installs an I-beam cursor rect that lingers after the field
// is gone; force the arrow back and rebuild cursor rects.
- (void)_resetCursorAfterEditing {
  [self.window invalidateCursorRectsForView:self];
  [[NSCursor arrowCursor] set];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
  if (_editingIndex < 0)
    return;
  // Defer so we're not mutating the view tree inside the field's callback.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self _commitRename];
  });
}

// Clicking another row's button doesn't change first responder (buttons don't
// take focus on click), so the editing field never gets its end-of-edit and
// the rename would stay live. Commit it before handling any other interaction.
- (void)_commitRenameIfEditing {
  if (_editingIndex < 0)
    return;
  [self.window makeFirstResponder:nil];
  [self _commitRename];
}

@end
