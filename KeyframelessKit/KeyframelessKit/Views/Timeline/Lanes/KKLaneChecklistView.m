/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneChecklistView.h"

#import "KKLaneCategoryNav.h"
#import "KKLocalized.h"
#import "KKPaddedScrollView.h"
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
  return [self initWithLanes:lanes
               minimumHeight:minimumHeight
                       width:kPopoverW
               maxBodyHeight:0.0];
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                        width:(CGFloat)width
                maxBodyHeight:(CGFloat)maxBodyHeight {
  return [self initWithLanes:lanes
               minimumHeight:0.0
                       width:width
               maxBodyHeight:maxBodyHeight];
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                minimumHeight:(CGFloat)minimumHeight
                        width:(CGFloat)width
                maxBodyHeight:(CGFloat)maxBodyHeight {
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
  self = [super initWithFrame:NSMakeRect(0, 0, width, h)];
  if (!self)
    return nil;
  _minimumHeight = minimumHeight;
  _width = width;
  _maxBodyHeight = maxBodyHeight;
  // Embedded (hosted in another popover) exactly when a body cap is given. MUST
  // be set before -_buildChromeForLanes: - that's where the scroll view is
  // built off this flag; setting it after leaves the rows un-scrolled (they
  // overflow the host with no clip / fade / hit-testing past the edge).
  _embedded = maxBodyHeight > 0.0;
  _lanes = [lanes copy];
  _allRows = [NSMutableArray array];
  _rowCategoryByLabel = catByLabel;
  _hasPill = hasPill;
  _selectedCategory = selected;
  [self _buildChromeForLanes:lanes];
  return self;
}

// Cap a visible-row count to what fits in `_maxBodyHeight` (0 = uncapped); the
// scroll view shows this many rows and scrolls the rest.
- (NSInteger)_cappedRowCount:(NSInteger)count {
  if (_maxBodyHeight <= 0.0)
    return count;
  NSInteger maxRows = (NSInteger)(_maxBodyHeight / kRowHeight);
  if (maxRows < 1)
    maxRows = 1;
  return MIN(count, maxRows);
}

// Embedded total height for `rows` visible: top pad + (pill) + search + gap +
// the (capped) scroll body, flush to the bottom (no trailing pad - the host
// popover supplies the standard bottom padding, so the scroll fade meets that
// edge instead of floating above a double gap). Matches the constraint layout
// exactly so the scroll body is never clipped by the host popover edge.
- (CGFloat)_embeddedHeightForRows:(NSInteger)rows {
  CGFloat h = KKPaddingMD + kSearchH + KKSpacingSM + rows * kRowHeight;
  if (_hasPill)
    h += kChecklistPillH + KKSpacingSM;
  return h;
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

  if (_embedded) {
    // Capped, internally-scrolling area (top/bottom fade via
    // KKPaddedScrollView) so a long list never balloons the host popover; the
    // view owns its own (capped) height via `_heightConstraint`.
    _bodyScroll = [[KKPaddedScrollView alloc] initWithDocumentView:_rowStack
                                                           padding:0.0];
    _bodyScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_bodyScroll];
    _bodyHeightConstraint =
        [_bodyScroll.heightAnchor constraintEqualToConstant:kRowHeight];
    _heightConstraint =
        [self.heightAnchor constraintEqualToConstant:kRowHeight];
    [NSLayoutConstraint activateConstraints:@[
      [_bodyScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_bodyScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_bodyScroll.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor
                                            constant:KKSpacingSM],
      _bodyHeightConstraint,
      _heightConstraint,
    ]];
    return;
  }

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

- (_KKManageRow *)appendRowWithLabel:(NSString *)label
                         categoryKey:(NSString *)categoryKey
                         indentLevel:(NSInteger)indentLevel {
  _KKManageRow *row = [[_KKManageRow alloc] initWithFrame:NSZeroRect];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  row.rowLabel = label;
  row.categoryKey = categoryKey;
  row.indentLevel = indentLevel;
  [_rowStack addArrangedSubview:row];
  [row.widthAnchor constraintEqualToAnchor:_rowStack.widthAnchor].active = YES;
  [_allRows addObject:row];
  return row;
}

- (void)removeAllRows {
  for (_KKManageRow *row in _allRows)
    [row removeFromSuperview];
  [_allRows removeAllObjects];
}

- (void)refilterAndResize {
  if (_embedded)
    [self _applyFilterAndResize];
  else
    [self _applyFilter];
}

- (void)setLanes:(NSArray<KKLane *> *)lanes {
  NSArray<NSString *> *oldKeys = KKLaneCategoryKeys(_lanes);
  NSArray<NSString *> *newKeys = KKLaneCategoryKeys(lanes);
  _lanes = [lanes copy];
  // Common case (filter refresh, same owner): the category nav is unchanged, so
  // just refresh the rows - cheap, keeps the pill/search/scroll intact.
  if ([oldKeys isEqualToArray:newKeys]) {
    [self rebuildRows];
    return;
  }
  // A multi-owner re-scope changed the category set (e.g. an image's
  // Transform-only list -> a path's Core/Stroke/Transform): _hasPill + the pill
  // segments must change, so tear down and rebuild the chrome, then the rows.
  _hasPill = newKeys.count > 0;
  _selectedCategory = !_hasPill ? nil
                      : [newKeys containsObject:_selectedCategory]
                          ? _selectedCategory
                          : newKeys.firstObject;
  _heightConstraint.active = NO;
  _bodyHeightConstraint.active = NO;
  _heightConstraint = nil;
  _bodyHeightConstraint = nil;
  for (NSView *sub in [self.subviews copy])
    [sub removeFromSuperview];
  _categoryPill = nil;
  _searchField = nil;
  _rowStack = nil;
  _bodyScroll = nil;
  [self _buildChromeForLanes:lanes];
  [self rebuildRows];
}

- (NSArray<NSString *> *)currentLaneLabels {
  NSMutableArray<NSString *> *out =
      [NSMutableArray arrayWithCapacity:_lanes.count];
  for (KKLane *l in _lanes)
    if (l.label)
      [out addObject:l.label];
  return out;
}

- (void)rebuildRows {
  // Labels can be layer-tagged (multi-owner re-scope), so refresh the map.
  _rowCategoryByLabel = KKLaneCategoryByLabel(_lanes);
  [self removeAllRows];
  for (KKLane *lane in _lanes) {
    _KKManageRow *row = [self appendRowWithLabel:lane.label
                                     categoryKey:_rowCategoryByLabel[lane.label]
                                     indentLevel:0];
    // rowLabel stays the identity (used for checked-state / search); show the
    // lane's displayName so a dynamic plugin's stable key isn't user-facing.
    row.displayOverride = KKLocalizedParamName(lane.displayName);
    [self configureRow:row forLane:lane];
  }
  [self refilterAndResize];
}

- (nullable NSView *)rowViewForLabel:(NSString *)label {
  for (_KKManageRow *row in _allRows)
    if ([row.rowLabel isEqualToString:label])
      return row;
  return nil;
}

- (void)selectCategoryForLabel:(NSString *)label {
  if (!_hasPill || label.length == 0)
    return;
  NSString *cat = _rowCategoryByLabel[label];
  if (cat.length == 0 || [cat isEqualToString:_selectedCategory])
    return;
  _selectedCategory = cat;
  NSArray<NSString *> *keys = KKLaneCategoryKeys(_lanes);
  NSInteger idx = [keys indexOfObject:cat];
  if (idx != NSNotFound) {
    NSMutableArray<NSNumber *> *states =
        [NSMutableArray arrayWithCapacity:keys.count];
    for (NSInteger i = 0; i < (NSInteger)keys.count; i++)
      [states addObject:@(i == idx)];
    _categoryPill.states = states;
  }
  [self _applyFilterAndResize];
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
    NSString *cat = row.categoryKey;
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
  NSInteger visible = MAX([self _applyFilter], 1);
  if (_embedded)
    return [self _embeddedHeightForRows:[self _cappedRowCount:visible]];
  return MAX([[self class] heightForRowCount:visible hasPill:_hasPill],
             _minimumHeight);
}

- (void)_applyFilterAndResize {
  NSInteger visible = MAX([self _applyFilter], 1);
  if (_embedded) {
    NSInteger capped = [self _cappedRowCount:visible];
    _bodyHeightConstraint.constant = capped * kRowHeight;
    _heightConstraint.constant = [self _embeddedHeightForRows:capped];
    return;
  }
  if (self.popover)
    self.popover.contentSize =
        NSMakeSize(kPopoverW, MAX([[self class] heightForRowCount:visible
                                                          hasPill:_hasPill],
                                  _minimumHeight));
}

- (void)controlTextDidChange:(NSNotification *)note {
  [self _applyFilterAndResize];
}

@end
