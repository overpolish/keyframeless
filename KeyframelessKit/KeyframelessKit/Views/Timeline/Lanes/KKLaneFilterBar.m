/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneFilterBar.h"
#import "KKLaneFilterChecklistView.h"
#import "KKLaneFilterModel.h"
#import "KKLocalized.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

static const CGFloat kLaneFilterIconSize = 16.0;

@implementation KKLaneFilterBar {
  KKLaneFilterModel *_model;
  NSArray<KKLane *>
      *_lanes;             // current lane set, for the checklist's rows + pill
  NSButton *_filterButton; // opens the checklist popover
  NSButton *_clearButton;  // to the right of the icon; resets to show-all
  // The cluster hugs just the filter glyph when nothing is filtered, and grows
  // to include the clear glyph when a filter is active.
  NSLayoutConstraint *_trailingNoClear;
  NSLayoutConstraint *_trailingWithClear;
  // The open checklist popover + its content view, so a toggle can push fresh
  // states back and a second icon tap can dismiss it.
  __weak NSPopover *_openPopover;
  __weak KKLaneFilterChecklistView *_openList;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  _lanes = [lanes copy];
  _model = [[KKLaneFilterModel alloc] initWithLanes:lanes];
  [self _buildButtons];
  [self _syncButtons];
  return self;
}

#pragma mark - Public API (delegates to the model)

- (void)applyLanes:(NSArray<KKLane *> *)lanes {
  if (![_model applyLanes:lanes])
    return;
  // The lane set changed, so an open checklist's rows are stale - refresh the
  // stored lanes and close the popover (the user can reopen onto the fresh
  // set).
  _lanes = [lanes copy];
  [_openPopover close];
  [self _syncButtons];
}

- (NSSet<NSString *> *)hiddenLabels {
  return [_model hiddenLabels];
}

- (void)showAllLanes {
  [_model showAll];
  [self _emitVisibilityChange];
}

- (void)applyHiddenLabels:(NSSet<NSString *> *)hidden {
  [_model applyHidden:hidden];
  [self _emitVisibilityChange];
}

#pragma mark - Buttons

static NSButton *_kkGlyphButton(NSString *symbol, CGFloat pt, id target,
                                SEL action) {
  NSImage *img = [[NSImage imageWithSystemSymbolName:symbol
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:pt
                                  weight:NSFontWeightRegular]];
  NSButton *b = [NSButton buttonWithImage:img target:target action:action];
  b.bordered = NO;
  b.imagePosition = NSImageOnly;
  b.translatesAutoresizingMaskIntoConstraints = NO;
  return b;
}

// A compact filter glyph opens the checklist; a clear glyph to its right (shown
// only while a filter is active) resets to all. The cluster lives in the
// header's accessory button row, so it hugs its content rather than stretching.
- (void)_buildButtons {
  _filterButton = _kkGlyphButton(@"line.3.horizontal.decrease.circle", 11.0,
                                 self, @selector(_filterTapped:));
  _filterButton.toolTip =
      KKLoc(@"Filter properties", @"Tooltip: filter which lanes are shown.");
  [self addSubview:_filterButton];

  _clearButton = _kkGlyphButton(@"xmark", 9.0, self, @selector(_clearTapped:));
  _clearButton.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  _clearButton.hidden = YES;
  [self addSubview:_clearButton];

  [NSLayoutConstraint activateConstraints:@[
    [_filterButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_filterButton.topAnchor constraintEqualToAnchor:self.topAnchor],
    [_filterButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [_filterButton.widthAnchor constraintEqualToConstant:kLaneFilterIconSize],
    [_filterButton.heightAnchor constraintEqualToConstant:kLaneFilterIconSize],

    [_clearButton.leadingAnchor
        constraintEqualToAnchor:_filterButton.trailingAnchor
                       constant:KKSpacingXS],
    [_clearButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_clearButton.widthAnchor constraintEqualToConstant:kLaneFilterIconSize],
    [_clearButton.heightAnchor constraintEqualToConstant:kLaneFilterIconSize],
  ]];
  // Trailing edge follows the clear button when it shows, else hugs the filter
  // glyph - toggled in -_syncButtons.
  _trailingNoClear = [self.trailingAnchor
      constraintEqualToAnchor:_filterButton.trailingAnchor];
  _trailingWithClear =
      [self.trailingAnchor constraintEqualToAnchor:_clearButton.trailingAnchor];
}

- (void)_clearTapped:(id)sender {
  [self showAllLanes];
  if (self.onUserToggled)
    self.onUserToggled();
}

// Tint the filter glyph in the warning colour and reveal the clear button only
// while a filter is active; otherwise dim the glyph and hide clear.
- (void)_syncButtons {
  BOOL active = _model.filterActive;
  _filterButton.contentTintColor =
      active ? [NSColor warning]
             : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  _clearButton.hidden = !active;
  _trailingWithClear.active = active;
  _trailingNoClear.active = !active;
}

#pragma mark - Layer scoping

// Multi-owner: only the active layer's lanes (matched by layerKey).
// Single-owner (no lane carries a layerKey): every lane. When no layer is
// selected yet (initial render, before the host pushes a selection), default to
// the FIRST layer in stack order - the topmost, which is what the host resolves
// a nil selection to - rather than spilling every layer's lanes into the
// popover.
- (NSArray<KKLane *> *)_scopedLanes {
  NSString *targetKey = _activeLayerKey;
  if (targetKey.length == 0)
    for (KKLane *l in _lanes)
      if (l.layerKey.length) {
        targetKey = l.layerKey;
        break;
      }
  if (targetKey.length == 0)
    return _lanes; // single-owner: no layers to scope by
  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  for (KKLane *l in _lanes)
    if ([l.layerKey isEqualToString:targetKey])
      [out addObject:l];
  return out;
}

- (void)setActiveLayerKey:(NSString *)activeLayerKey {
  if (_activeLayerKey == activeLayerKey ||
      [_activeLayerKey isEqualToString:activeLayerKey])
    return;
  _activeLayerKey = [activeLayerKey copy];
  // Re-scope an open checklist to the newly-selected layer (the companion layer
  // list drove the switch), mirroring the Animated dropdown.
  [_openList reloadLanes:[self _scopedLanes]
           visibleLabels:[self _visibleLabels]
            soloedLabels:[_model soloedLabels]];
}

#pragma mark - Popover

// Visible = every scoped lane whose label isn't hidden.
- (NSSet<NSString *> *)_visibleLabels {
  NSSet<NSString *> *hidden = [_model hiddenLabels];
  NSMutableSet<NSString *> *visible = [NSMutableSet set];
  for (KKLane *l in [self _scopedLanes])
    if (![hidden containsObject:l.label])
      [visible addObject:l.label];
  return visible;
}

// Build the checklist scoped to the active layer, wired to the model's
// per-label mutators. Toggle/solo run -_emitVisibilityChange, which reloads the
// open list with the model's fresh (cascaded) state, so the blocks don't reload
// here.
- (KKLaneFilterChecklistView *)_makeChecklist {
  KKLaneFilterChecklistView *list =
      [[KKLaneFilterChecklistView alloc] initWithLanes:[self _scopedLanes]
                                         visibleLabels:[self _visibleLabels]
                                          soloedLabels:[_model soloedLabels]
                                         minimumHeight:_minimumPopoverHeight];
  list.frame = NSMakeRect(0, 0, [KKLaneFilterChecklistView preferredWidth],
                          list.fittingHeight);
  __weak typeof(self) weak = self;
  list.onToggled = ^(NSString *label, BOOL on) {
    [weak _toggleLabel:label on:on];
  };
  list.onSolo = ^(NSString *label) {
    [weak _soloLabel:label];
  };
  return list;
}

- (void)_filterTapped:(id)sender {
  if (_openPopover.isShown) {
    [_openPopover close];
    return;
  }
  if (!self.popoverPresenter)
    return;
  KKLaneFilterChecklistView *list = [self _makeChecklist];
  __weak typeof(self) weak = self;
  NSPopover *pop = self.popoverPresenter(list, _filterButton, ^{
    __strong typeof(weak) s = weak;
    s->_openPopover = nil;
    s->_openList = nil;
  });
  list.popover = pop;
  _openPopover = pop;
  _openList = list;
}

- (void)closeFilterPopover {
  [_openPopover close];
}

#pragma mark - Model forwarding

- (void)_emitVisibilityChange {
  [self _syncButtons];
  [_openList reloadVisibleLabels:[self _visibleLabels]
                    soloedLabels:[_model soloedLabels]];
  if (self.onVisibilityChanged)
    self.onVisibilityChanged([_model hiddenLabels]);
}

- (void)_toggleLabel:(NSString *)label on:(BOOL)on {
  [_model setLabel:label visible:on];
  [self _emitVisibilityChange];
  if (self.onUserToggled)
    self.onUserToggled();
}

- (void)_soloLabel:(NSString *)label {
  [_model soloLabel:label];
  [self _emitVisibilityChange];
  if (self.onUserToggled)
    self.onUserToggled();
}

@end
