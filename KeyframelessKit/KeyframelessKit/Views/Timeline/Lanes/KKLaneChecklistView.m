/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneChecklistView.h"

#import "KKLaneCategoryNav.h"
#import "KKLocalized.h"
#import "KKPillBar.h"
#import "KKPillToggleRowView.h"
#import "KKTimelineLanesView_Private.h" // _KKManageRow, _KKSearchField, tokens
#import "KKTokens.h"

static const CGFloat kChecklistPillH = 24.0;

@implementation _KKLaneChecklistView

+ (CGFloat)preferredWidth {
  return kPopoverW;
}

+ (CGFloat)heightForRowCount:(NSInteger)count hasPill:(BOOL)hasPill {
  CGFloat h = KKPaddingMD + kSearchH + KKPaddingMD;
  if (hasPill)
    h += kChecklistPillH + KKSpacingSM;
  return h + count * kRowHeight + KKPaddingMD;
}

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                minimumHeight:(CGFloat)minimumHeight {
  NSDictionary<NSString *, NSString *> *catByLabel =
      KKLaneCategoryByLabel(lanes);
  NSArray<NSString *> *keys = KKLaneCategoryKeys(lanes);
  BOOL hasPill = keys.count > 0;
  NSString *selected = hasPill ? keys.firstObject : nil;

  // Open hugging the first category's page (or all rows when there's no pill);
  // it resizes as the pill/search narrows the list.
  NSInteger initialVisible = 0;
  for (KKLane *lane in lanes)
    if (!hasPill || catByLabel[lane.label] == nil ||
        [catByLabel[lane.label] isEqualToString:selected])
      initialVisible++;
  CGFloat h = MAX([[self class] heightForRowCount:initialVisible
                                          hasPill:hasPill],
                  minimumHeight);
  self = [super initWithFrame:NSMakeRect(0, 0, kPopoverW, h)];
  if (!self)
    return nil;
  _minimumHeight = minimumHeight;
  _lanes = [lanes copy];
  _allRows = [NSMutableArray array];
  _rowCategoryByLabel = catByLabel;
  _hasPill = hasPill;
  _selectedCategory = selected;
  [self _buildChromeForLanes:lanes];
  return self;
}

// Search field, the optional category pill nav, and the (empty) row stack.
- (void)_buildChromeForLanes:(NSArray<KKLane *> *)lanes {
  _searchField = [[_KKSearchField alloc] init];
  _searchField.translatesAutoresizingMaskIntoConstraints = NO;
  _searchField.placeholderString =
      KKLoc(@"Search", @"Placeholder: search properties.");
  _searchField.delegate = self;
  _searchField.font = [NSFont systemFontOfSize:KKFontSizeSM
                                        weight:NSFontWeightRegular];
  _searchField.focusRingType = NSFocusRingTypeNone;

  NSLayoutYAxisAnchor *searchTop = self.topAnchor;
  CGFloat searchTopInset = KKPaddingMD;
  if (_hasPill) {
    searchTop = [self _buildCategoryPillForLanes:lanes].bottomAnchor;
    searchTopInset = KKSpacingSM;
  }

  [self addSubview:_searchField];
  [NSLayoutConstraint activateConstraints:@[
    [_searchField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                               constant:KKPaddingMD],
    [_searchField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                constant:-KKPaddingMD],
    [_searchField.topAnchor constraintEqualToAnchor:searchTop
                                           constant:searchTopInset],
    [_searchField.heightAnchor constraintEqualToConstant:kSearchH],
  ]];

  _rowStack = [NSStackView stackViewWithViews:@[]];
  _rowStack.translatesAutoresizingMaskIntoConstraints = NO;
  _rowStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _rowStack.spacing = 0;
  _rowStack.detachesHiddenViews = YES;
  [self addSubview:_rowStack];
  [NSLayoutConstraint activateConstraints:@[
    [_rowStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_rowStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_rowStack.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor
                                        constant:KKSpacingSM],
  ]];
}

// The category pill wrapped in a horizontal edge-faded scroll so a long
// category run stays on one row and scrolls instead of forcing the popover
// wide. Returns the wrapper for anchoring the search field below it.
- (KKPillBar *)_buildCategoryPillForLanes:(NSArray<KKLane *> *)lanes {
  __weak typeof(self) weak = self;
  _categoryPill = KKMakeLaneCategoryPill(lanes, _selectedCategory,
                                         ^(NSString *categoryKey) {
                                           __strong typeof(weak) ss = weak;
                                           if (!ss)
                                             return;
                                           ss->_selectedCategory = categoryKey;
                                           [ss _applyFilterAndResize];
                                         });
  KKPillBar *pillBar = [[KKPillBar alloc] initWithPillRow:_categoryPill];
  pillBar.translatesAutoresizingMaskIntoConstraints = NO;
  // Hug content when it fits, but a near-zero compression resistance lets it
  // shrink so the inner scroll takes over on overflow (vs clipping full-width).
  [pillBar setContentHuggingPriority:NSLayoutPriorityRequired - 1
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
  [pillBar
      setContentCompressionResistancePriority:1
                               forOrientation:
                                   NSLayoutConstraintOrientationHorizontal];
  [self addSubview:pillBar];
  [NSLayoutConstraint activateConstraints:@[
    [pillBar.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [pillBar.leadingAnchor
        constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                    constant:KKPaddingMD],
    [pillBar.trailingAnchor
        constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                 constant:-KKPaddingMD],
    [pillBar.topAnchor constraintEqualToAnchor:self.topAnchor
                                      constant:KKPaddingMD],
    [pillBar.heightAnchor constraintEqualToConstant:kChecklistPillH],
  ]];
  return pillBar;
}

#pragma mark - Rows

- (void)configureRow:(_KKManageRow *)row forLane:(KKLane *)lane {
  // Subclass hook - default no-op.
}

- (void)setLanes:(NSArray<KKLane *> *)lanes {
  _lanes = [lanes copy];
  [self rebuildRows];
}

- (void)rebuildRows {
  // Labels can be layer-tagged (multi-owner re-scope), so refresh the map.
  _rowCategoryByLabel = KKLaneCategoryByLabel(_lanes);
  for (_KKManageRow *row in _allRows)
    [row removeFromSuperview];
  [_allRows removeAllObjects];
  for (KKLane *lane in _lanes) {
    _KKManageRow *row = [[_KKManageRow alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.rowLabel = lane.label;
    [self configureRow:row forLane:lane];
    [_rowStack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_rowStack.widthAnchor].active =
        YES;
    [_allRows addObject:row];
  }
  [self _applyFilter];
}

- (nullable NSView *)rowViewForLabel:(NSString *)label {
  for (_KKManageRow *row in _allRows)
    if ([row.rowLabel isEqualToString:label])
      return row;
  return nil;
}

#pragma mark - Filtering + sizing

// Hide rows outside the selected category, and within it rows that don't match
// the search query (search is scoped to the current category). Returns the
// visible row count so the popover can resize to hug it.
- (NSInteger)_applyFilter {
  NSString *query = _searchField.stringValue;
  BOOL searching = query.length > 0;
  NSInteger visible = 0;
  for (_KKManageRow *row in _allRows) {
    BOOL matchSearch =
        !searching || [row.rowLabel rangeOfString:query
                                          options:NSCaseInsensitiveSearch]
                              .location != NSNotFound;
    NSString *cat = _rowCategoryByLabel[row.rowLabel];
    BOOL matchCategory =
        !_hasPill || cat.length == 0 || [cat isEqualToString:_selectedCategory];
    BOOL show = matchSearch && matchCategory;
    row.hidden = !show;
    if (show)
      visible++;
  }
  return visible;
}

- (CGFloat)fittingHeight {
  return MAX([[self class] heightForRowCount:MAX([self _applyFilter], 1)
                                     hasPill:_hasPill],
             _minimumHeight);
}

- (void)_applyFilterAndResize {
  NSInteger visible = [self _applyFilter];
  if (self.popover)
    self.popover.contentSize = NSMakeSize(
        kPopoverW, MAX([[self class] heightForRowCount:MAX(visible, 1)
                                               hasPill:_hasPill],
                       _minimumHeight));
}

- (void)controlTextDidChange:(NSNotification *)note {
  [self _applyFilterAndResize];
}

@end
