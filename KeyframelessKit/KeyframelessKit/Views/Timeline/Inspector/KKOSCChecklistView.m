/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCChecklistView.h"

#import "KKLocalized.h"
#import "KKOSCVisibilityDefaults.h"
#import "KKPaddedScrollView.h"
#import "KKTimelineLanesView_Private.h" // _KKManageRow, _KKSearchField, tokens
#import "KKTokens.h"
#import "NSColor+KKColors.h"

// Cap the row area at this many rows; beyond it the list scrolls (with the
// scroll view's top/bottom fade shadows) instead of growing the popover.
static const NSInteger kOSCMaxVisibleRows = 6;

// The [Reset][Make Default] row between the search field and the list.
static const CGFloat kOSCDefaultsRowH = 20.0;

@interface KKOSCChecklistView () <NSSearchFieldDelegate>
@end

@implementation KKOSCChecklistView {
  NSArray<NSArray<NSString *> *> *_compounds;
  NSMutableArray<NSMutableArray<NSNumber *> *> *_states;
  _KKSearchField *_search;
  KKPaddedScrollView *_scroll;
  NSLayoutConstraint
      *_scrollHeight; // capped row-area height; tracks the filter
  NSStackView *_rowStack;
  NSMutableArray<_KKManageRow *> *_rows;
  // Parallel to `_rows`: each row's (compoundIndex, segmentIndex) so a toggle /
  // spotlight maps straight back to the inspector's compound coordinates.
  NSMutableArray<NSNumber *> *_rowCompound;
  NSMutableArray<NSNumber *> *_rowSegment;
  NSView *_defaultsRow;
  NSLayoutConstraint *_defaultsRowHeight; // collapses to 0 when both hide
  NSLayoutConstraint *_scrollTopGap;      // row -> list gap, collapses with it
  NSButton *_makeDefaultButton;
  NSButton *_resetDefaultButton;
  NSString * (^_displayForKey)(NSString *);
}

+ (CGFloat)preferredWidth {
  return kPopoverW;
}

- (BOOL)isFlipped {
  return YES;
}

// A compound element is a CHILD when its key is dot-prefixed by an earlier key
// in the same compound (e.g. `Rotation.X` under `Rotation`); such rows indent
// one level. Everything else is top level.
static NSInteger KKOSCIndentForKey(NSArray<NSString *> *compound,
                                   NSInteger segIdx) {
  NSString *key = compound[segIdx];
  for (NSInteger j = 0; j < segIdx; j++) {
    NSString *prefix = [compound[j] stringByAppendingString:@"."];
    if ([key hasPrefix:prefix])
      return 1;
  }
  return 0;
}

- (instancetype)initWithCompounds:(NSArray<NSArray<NSString *> *> *)compounds
                           states:(NSArray<NSArray<NSNumber *> *> *)states {
  return [self initWithCompounds:compounds states:states displayForKey:nil];
}

- (instancetype)initWithCompounds:(NSArray<NSArray<NSString *> *> *)compounds
                           states:(NSArray<NSArray<NSNumber *> *> *)states
                    displayForKey:(NSString * (^)(NSString *))displayForKey {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  _displayForKey = [displayForKey copy];
  _compounds = [compounds copy];
  _states = [NSMutableArray array];
  for (NSArray<NSNumber *> *s in states)
    [_states addObject:[s mutableCopy]];
  _rows = [NSMutableArray array];
  _rowCompound = [NSMutableArray array];
  _rowSegment = [NSMutableArray array];

  // Give the list a definite width so the popover sizes to it (its rows /
  // search field are only leading/trailing-pinned, so without this the content
  // has an ambiguous fitting width and the popover collapses to zero).
  [self.widthAnchor
      constraintEqualToConstant:[KKOSCChecklistView preferredWidth]]
      .active = YES;

  _search = [[_KKSearchField alloc] init];
  _search.translatesAutoresizingMaskIntoConstraints = NO;
  _search.placeholderString =
      KKLoc(@"Search", @"Placeholder: search controls.");
  _search.delegate = self;
  _search.font = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightRegular];
  _search.focusRingType = NSFocusRingTypeNone;
  [self addSubview:_search];
  [NSLayoutConstraint activateConstraints:@[
    [_search.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:KKPaddingMD],
    [_search.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-KKPaddingMD],
    [_search.topAnchor constraintEqualToAnchor:self.topAnchor
                                      constant:KKPaddingMD],
    [_search.heightAnchor constraintEqualToConstant:kSearchH],
  ]];

  [self _buildDefaultsRowBelow:_search];

  _rowStack = [NSStackView stackViewWithViews:@[]];
  _rowStack.translatesAutoresizingMaskIntoConstraints = NO;
  _rowStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _rowStack.spacing = 0;
  _rowStack.detachesHiddenViews = YES;
  // Wrap the rows in a capped-height scroll view; -fittingHeight bounds the
  // popover at kOSCMaxVisibleRows, and KKPaddedScrollView fades the top/bottom
  // edges as the list scrolls past them.
  _scroll = [[KKPaddedScrollView alloc] initWithDocumentView:_rowStack
                                                     padding:0.0];
  _scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_scroll];
  [NSLayoutConstraint activateConstraints:@[
    [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    (_scrollTopGap =
         [_scroll.topAnchor constraintEqualToAnchor:_defaultsRow.bottomAnchor
                                           constant:KKSpacingSM]),
    // Flush to the bottom edge so the bottom fade shadow meets the popover edge
    // (no trailing margin below the list).
    [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
  ]];
  // KKPaddedScrollView has no intrinsic height, so pin it explicitly (else it
  // collapses to nothing and only the search bar shows). Updated by the filter.
  _scrollHeight = [_scroll.heightAnchor constraintEqualToConstant:0.0];
  _scrollHeight.active = YES;

  for (NSInteger ci = 0; ci < (NSInteger)_compounds.count; ci++) {
    NSArray<NSString *> *compound = _compounds[ci];
    for (NSInteger si = 0; si < (NSInteger)compound.count; si++) {
      _KKManageRow *row = [[_KKManageRow alloc] initWithFrame:NSZeroRect];
      row.translatesAutoresizingMaskIntoConstraints = NO;
      // Raw leaf key (e.g. "Rotation.X" -> "X"); _KKManageRow localizes it at
      // draw time, like the manage dropdown's rows.
      row.rowLabel = [compound[si] componentsSeparatedByString:@"."].lastObject
                         ?: compound[si];
      // rowLabel stays the identity (guide reporting keys on it); show the
      // plugin's display name for this element when provided.
      NSString *disp = _displayForKey ? _displayForKey(compound[si]) : nil;
      if (disp.length)
        row.displayOverride = disp;
      row.checked =
          (si < (NSInteger)_states[ci].count) ? _states[ci][si].boolValue : NO;
      row.indentLevel = KKOSCIndentForKey(compound, si);
      NSInteger capCI = ci, capSI = si;
      __weak typeof(self) weak = self;
      row.onToggle = ^{
        [weak _toggleCompound:capCI segment:capSI];
      };
      [_rowStack addArrangedSubview:row];
      [row.widthAnchor constraintEqualToAnchor:_rowStack.widthAnchor].active =
          YES;
      [_rows addObject:row];
      [_rowCompound addObject:@(ci)];
      [_rowSegment addObject:@(si)];
    }
  }
  _scrollHeight.constant = [self _rowAreaHeight];
  [self _updateDefaultsRow];
  return self;
}

// One flat text-and-glyph action, matching the curve popover's title-bar pair:
// no bezel, no background, accent for the save, grey for the revert.
static NSButton *KKOSCDefaultsButton(NSString *title, NSString *symbol,
                                     NSColor *tint, id target, SEL action) {
  NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.controlSize = NSControlSizeSmall;
  b.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
  b.image = [NSImage imageWithSystemSymbolName:symbol
                      accessibilityDescription:title];
  b.imagePosition = b.image ? NSImageLeading : NSNoImage;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.contentTintColor = tint;
  b.imageHugsTitle = YES;
  // See KKSegmentEditView: opened over another popover, the release lands in
  // that popover's window, so a release-driven button never fires its action.
  [b sendActionOn:NSEventMaskLeftMouseDown];
  return b;
}

// "Make Default" saves which controls are hidden right now as the starting set
// for every new clip (and, in Canvas, every new layer of this kind); "Reset"
// puts this clip back to that saved set. Both hide while the two already match.
- (void)_buildDefaultsRowBelow:(NSView *)anchorView {
  _defaultsRow = [[NSView alloc] initWithFrame:NSZeroRect];
  _defaultsRow.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_defaultsRow];

  _resetDefaultButton = KKOSCDefaultsButton(
      KKLoc(@"Reset", @"Button: restore the saved default curve."),
      @"arrow.uturn.backward", [NSColor secondaryLabelColor], self,
      @selector(_resetToDefaultTapped:));
  _resetDefaultButton.toolTip =
      KKLoc(@"Put these controls back to the saved default",
            @"Tooltip for the OSC Reset button.");
  [_defaultsRow addSubview:_resetDefaultButton];

  _makeDefaultButton = KKOSCDefaultsButton(
      KKLoc(@"Make Default", @"Button: save these curve settings as default."),
      @"star", [NSColor accentMatchingHost], self,
      @selector(_makeDefaultTapped:));
  _makeDefaultButton.toolTip =
      KKLoc(@"Show this set of on-screen controls on every new clip",
            @"Tooltip for the OSC Make Default button.");
  [_defaultsRow addSubview:_makeDefaultButton];

  [NSLayoutConstraint activateConstraints:@[
    [_defaultsRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                               constant:KKPaddingMD],
    [_defaultsRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                constant:-KKPaddingMD],
    [_defaultsRow.topAnchor constraintEqualToAnchor:anchorView.bottomAnchor
                                           constant:KKSpacingSM],
    (_defaultsRowHeight = [_defaultsRow.heightAnchor
         constraintEqualToConstant:kOSCDefaultsRowH]),

    [_resetDefaultButton.leadingAnchor
        constraintEqualToAnchor:_defaultsRow.leadingAnchor],
    [_resetDefaultButton.centerYAnchor
        constraintEqualToAnchor:_defaultsRow.centerYAnchor],
    [_makeDefaultButton.trailingAnchor
        constraintEqualToAnchor:_defaultsRow.trailingAnchor],
    [_makeDefaultButton.centerYAnchor
        constraintEqualToAnchor:_defaultsRow.centerYAnchor],
  ]];
}

// The elements currently unchecked, in the same key space the default stores.
- (NSSet<NSString *> *)_hiddenKeys {
  NSMutableSet<NSString *> *hidden = [NSMutableSet set];
  for (NSInteger ci = 0; ci < (NSInteger)_compounds.count; ci++)
    for (NSInteger si = 0; si < (NSInteger)_compounds[ci].count; si++) {
      BOOL on = (ci < (NSInteger)_states.count &&
                 si < (NSInteger)_states[ci].count)
                    ? _states[ci][si].boolValue
                    : NO;
      if (!on)
        [hidden addObject:_compounds[ci][si]];
    }
  return hidden;
}

- (void)setDefaultsScope:(NSString *)defaultsScope {
  _defaultsScope = [defaultsScope copy];
  [self _updateDefaultsRow];
}

- (void)_updateDefaultsRow {
  if (!_makeDefaultButton)
    return;
  NSSet<NSString *> *saved = KKOSCVisibilityDefaultsRead(self.defaultsScope);
  // Compare only against keys this list actually has: a default saved on a
  // shader with more controls must still read as "already default" here.
  NSMutableSet<NSString *> *savedHere = [NSMutableSet set];
  for (NSArray<NSString *> *c in _compounds)
    for (NSString *key in c)
      if ([saved containsObject:key])
        [savedHere addObject:key];
  BOOL matches = saved && [savedHere isEqualToSet:[self _hiddenKeys]];
  _makeDefaultButton.hidden = matches;
  _resetDefaultButton.hidden = matches;
  // Collapse the row itself, not just its buttons - a hidden view keeps its
  // constraints, so leaving the height in place left a blank band above the
  // list. Re-fit the popover the same way the search filter does.
  _defaultsRow.hidden = matches;
  CGFloat wanted = matches ? 0.0 : kOSCDefaultsRowH;
  if (fabs(_defaultsRowHeight.constant - wanted) > 0.5) {
    _defaultsRowHeight.constant = wanted;
    // Its gap to the list goes with it, else a collapsed row still leaves a
    // double spacer under the search field.
    _scrollTopGap.constant = matches ? 0.0 : KKSpacingSM;
    if (self.popover)
      self.popover.contentSize =
          NSMakeSize([KKOSCChecklistView preferredWidth], [self fittingHeight]);
  }
}

- (void)_makeDefaultTapped:(id)sender {
  KKOSCVisibilityDefaultsWrite([self _hiddenKeys], self.defaultsScope);
  [self _updateDefaultsRow];
}

- (void)_resetToDefaultTapped:(id)sender {
  NSSet<NSString *> *saved = KKOSCVisibilityDefaultsRead(self.defaultsScope);
  if (!saved)
    return;
  // Flip through the normal toggle path so each change persists exactly as a
  // click would - the host owns the storage, this view only mirrors it.
  for (NSInteger ci = 0; ci < (NSInteger)_compounds.count; ci++)
    for (NSInteger si = 0; si < (NSInteger)_compounds[ci].count; si++) {
      if (ci >= (NSInteger)_states.count || si >= (NSInteger)_states[ci].count)
        continue;
      BOOL wanted = ![saved containsObject:_compounds[ci][si]];
      if (_states[ci][si].boolValue != wanted)
        [self _toggleCompound:ci segment:si];
    }
  [self _updateDefaultsRow];
}

// Height of the scrollable row area: the visible rows, capped at
// kOSCMaxVisibleRows (beyond which it scrolls).
- (CGFloat)_rowAreaHeight {
  NSInteger n = MAX([self _visibleRowCount], 1);
  return (CGFloat)MIN(n, kOSCMaxVisibleRows) * kRowHeight;
}

- (void)_toggleCompound:(NSInteger)ci segment:(NSInteger)si {
  if (ci < 0 || ci >= (NSInteger)_states.count || si < 0 ||
      si >= (NSInteger)_states[ci].count)
    return;
  BOOL now = !_states[ci][si].boolValue;
  _states[ci][si] = @(now);
  for (NSInteger r = 0; r < (NSInteger)_rows.count; r++)
    if (_rowCompound[r].integerValue == ci && _rowSegment[r].integerValue == si)
      _rows[r].checked = now;
  if (self.onToggled)
    self.onToggled(ci, si, now);
  // After the host has stored it, so the row reflects the committed state.
  [self _updateDefaultsRow];
}

- (void)reloadStates:(NSArray<NSArray<NSNumber *> *> *)states {
  if (states.count != _states.count)
    return;
  for (NSInteger i = 0; i < (NSInteger)states.count; i++)
    _states[i] = [states[i] mutableCopy];
  for (NSInteger r = 0; r < (NSInteger)_rows.count; r++) {
    NSInteger ci = _rowCompound[r].integerValue;
    NSInteger si = _rowSegment[r].integerValue;
    if (ci < (NSInteger)_states.count && si < (NSInteger)_states[ci].count)
      _rows[r].checked = _states[ci][si].boolValue;
  }
  [self _updateDefaultsRow];
}

- (NSInteger)_visibleRowCount {
  NSInteger n = 0;
  for (_KKManageRow *row in _rows)
    if (!row.hidden)
      n++;
  return n;
}

- (CGFloat)fittingHeight {
  // Flush bottom (no trailing pad) so the fade shadow reaches the popover edge.
  // Matches the live constraints: search gap + (row + its gap, when shown).
  CGFloat defaultsH =
      _defaultsRow.hidden ? 0.0 : (kOSCDefaultsRowH + KKSpacingSM);
  return KKPaddingMD + kSearchH + KKSpacingSM + defaultsH +
         [self _rowAreaHeight];
}

- (NSRect)screenRectForCompoundIndex:(NSInteger)compoundIndex {
  for (NSInteger r = 0; r < (NSInteger)_rows.count; r++) {
    if (_rowCompound[r].integerValue != compoundIndex)
      continue;
    _KKManageRow *row = _rows[r];
    NSWindow *w = row.window;
    if (!w)
      return NSZeroRect;
    return [w convertRectToScreen:[row convertRect:row.bounds toView:nil]];
  }
  return NSZeroRect;
}

// Hide rows whose label doesn't match the query (case-insensitive substring),
// then re-fit the popover to hug the visible rows - mirrors the manage popover.
- (void)_applyFilter {
  NSString *query = _search.stringValue;
  BOOL searching = query.length > 0;
  for (_KKManageRow *row in _rows) {
    BOOL match =
        !searching || [row.rowLabel rangeOfString:query
                                          options:NSCaseInsensitiveSearch]
                              .location != NSNotFound;
    row.hidden = !match;
  }
  _scrollHeight.constant = [self _rowAreaHeight];
  if (self.popover)
    self.popover.contentSize =
        NSMakeSize([KKOSCChecklistView preferredWidth], [self fittingHeight]);
}

- (void)controlTextDidChange:(NSNotification *)note {
  [self _applyFilter];
}

// Enter / Esc drop focus (blur) so spacebar (playback) and Esc (close popover)
// reach the popover again, matching every other field in a ViewBridge popover.
- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)selector {
  if (selector == @selector(insertNewline:) ||
      selector == @selector(cancelOperation:)) {
    [control.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

@end
