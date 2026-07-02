/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCChecklistView.h"

#import "KKLocalized.h"
#import "KKPaddedScrollView.h"
#import "KKTimelineLanesView_Private.h" // _KKManageRow, _KKSearchField, tokens
#import "KKTokens.h"

// Cap the row area at this many rows; beyond it the list scrolls (with the
// scroll view's top/bottom fade shadows) instead of growing the popover.
static const NSInteger kOSCMaxVisibleRows = 6;

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
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
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
    [_scroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor
                                      constant:KKSpacingSM],
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
  return self;
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
  return KKPaddingMD + kSearchH + KKSpacingSM + [self _rowAreaHeight];
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

@end
