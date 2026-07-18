/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderBrowserView.h"

#import "ShaderBrowserInternal.h"
#import "ShaderCategory.h"
#import "ShaderLocalCatalog.h"
#import "ShaderLocalized.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>
@import KKCommunity;

static const CGFloat kCardGap = 10.0;
static const CGFloat kHeaderH = 22.0;

@interface ShaderBrowserView () <_ShaderCardOwner, NSSearchFieldDelegate>
@end

@implementation ShaderBrowserView {
  NSTextField *_title;
  _ShaderSearchField *_search;
  id _searchOutsideClickMon; // blur the search field on an outside click
  NSButton *_favFilter;
  NSButton *_refreshButton;
  KKPillToggleRowView *_categoryPills;
  NSView *_well;
  KKPaddedScrollView *_scrollContainer; // shared scroll + edge-fade shadows
  _ShaderFlippedView *_doc;
  NSTextField *_empty;
  NSMutableArray<_ShaderCard *> *_cards;
  _ShaderCard *_hovered;
  id _mouseMonitor;
  NSArray<_ShaderBrowserItem *> *_community; // raw fetched (entryID + entry)
  NSMutableDictionary<NSString *, NSImage *> *_communityThumbnails;
  BOOL _fetching;
  NSString *_query;
  BOOL _favoritesOnly;
  /// Category ids currently filtered to. EMPTY = no category filter (show all),
  /// which is why this is a set of what's ON rather than a per-pill toggle: "no
  /// pills lit" and "every pill lit" would otherwise be different states that
  /// show the same thing.
  NSMutableSet<NSString *> *_categoryFilter;
  BOOL _renaming;     // a card is inline-editing; don't destroy it in a rebuild
  BOOL _needsRebuild; // a rebuild was requested while renaming
  CGFloat _cardW, _cardH; // computed per rebuild (2-column 50/50 split)
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self)
    return nil;
  _cards = [NSMutableArray array];
  _community = @[];
  _communityThumbnails = [NSMutableDictionary dictionary];
  _query = @"";

  _title = [NSTextField labelWithString:RLoc(@"Shaders", @"Browser title.")];
  _title.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
  _title.textColor = [NSColor secondaryLabelColor];
  _title.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_title];

  _search = [[_ShaderSearchField alloc] initWithFrame:NSZeroRect];
  _search.translatesAutoresizingMaskIntoConstraints = NO;
  _search.placeholderString = RLoc(@"Search", @"Search placeholder.");
  _search.controlSize = NSControlSizeSmall;
  _search.font = [NSFont systemFontOfSize:11.0];
  _search.focusRingType = NSFocusRingTypeNone;
  _search.delegate = self;
  [self addSubview:_search];

  // Drop focus on a click outside the search field (persistent monitor gated on
  // editing; the popover won't resign it on its own, and NSSearchField's
  // throttled-search cycling makes begin/end-editing unreliable to hook).
  _searchOutsideClickMon = KKMakeFieldOutsideClickMonitor(_search);

  _favFilter = [self _headerToggle:@"star"
                            action:@selector(_toggleFavFilter:)
                           tooltip:RLoc(@"Favourites only", @"Fav filter.")];
  [self addSubview:_favFilter];

  _refreshButton = [self _headerToggle:@"arrow.clockwise"
                                action:@selector(_refresh:)
                               tooltip:RLoc(@"Refresh", @"Refresh shaders.")];
  [self addSubview:_refreshButton];

  _categoryFilter = [NSMutableSet set];
  _categoryPills = [self _buildCategoryPills];
  [self addSubview:_categoryPills];

  _well = [NSView new];
  _well.translatesAutoresizingMaskIntoConstraints = NO;
  _well.wantsLayer = YES;
  _well.layer.cornerRadius = KKRadiusMD;
  _well.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.2].CGColor;
  _well.layer.borderColor = NSColor.separatorColor.CGColor;
  _well.layer.borderWidth = 1.0;
  _well.layer.masksToBounds = YES;
  [self addSubview:_well];

  // The shared scroll container owns the scroll view, the flipped clip, and the
  // top/bottom edge-fade shadows (alpha crossfades with scroll position). Same
  // component the constants popover and the other plugins use - don't hand-roll
  // the fades. The doc grows by its intrinsic height (set per rebuild).
  _doc = [[_ShaderFlippedView alloc] initWithFrame:NSZeroRect];
  _scrollContainer = [[KKPaddedScrollView alloc] initWithDocumentView:_doc
                                                              padding:0];
  _scrollContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [_well addSubview:_scrollContainer];

  _empty = [self _centeredLabel:@""];
  _empty.hidden = YES;
  [_well addSubview:_empty];

  [NSLayoutConstraint activateConstraints:@[
    [_title.topAnchor constraintEqualToAnchor:self.topAnchor
                                     constant:KKPaddingMD],
    [_title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:KKPaddingMD + 2],
    [_search.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
    [_search.leadingAnchor constraintEqualToAnchor:_title.trailingAnchor
                                          constant:8],
    [_favFilter.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
    [_favFilter.leadingAnchor constraintEqualToAnchor:_search.trailingAnchor
                                             constant:6],
    [_favFilter.widthAnchor constraintEqualToConstant:18],
    [_refreshButton.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
    [_refreshButton.leadingAnchor
        constraintEqualToAnchor:_favFilter.trailingAnchor
                       constant:6],
    [_refreshButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                  constant:-10],
    [_refreshButton.widthAnchor constraintEqualToConstant:18],
    // Its own row: five icon pills plus the title/search/star/refresh chain
    // would crush the search field at a 300pt panel width.
    [_categoryPills.topAnchor constraintEqualToAnchor:_search.bottomAnchor
                                             constant:KKPaddingSM],
    [_categoryPills.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    // Centred, but never past the edges if the panel is ever narrower than the
    // row wants to be.
    [_categoryPills.leadingAnchor
        constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                    constant:KKPaddingMD],
    [_categoryPills.trailingAnchor
        constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                 constant:-10],
    [_well.topAnchor constraintEqualToAnchor:_categoryPills.bottomAnchor
                                    constant:KKPaddingSM],
    [_well.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:KKPaddingSM],
    [_well.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-KKPaddingSM],
    [_well.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                       constant:-KKPaddingSM],
    [_scrollContainer.topAnchor constraintEqualToAnchor:_well.topAnchor],
    [_scrollContainer.leadingAnchor
        constraintEqualToAnchor:_well.leadingAnchor],
    [_scrollContainer.trailingAnchor
        constraintEqualToAnchor:_well.trailingAnchor],
    [_scrollContainer.bottomAnchor constraintEqualToAnchor:_well.bottomAnchor],
    [_empty.centerXAnchor constraintEqualToAnchor:_well.centerXAnchor],
    [_empty.centerYAnchor constraintEqualToAnchor:_well.centerYAnchor],
    [_empty.widthAnchor constraintLessThanOrEqualToAnchor:_well.widthAnchor
                                                 constant:-24],
  ]];
  return self;
}

- (NSTextField *)_centeredLabel:(NSString *)text {
  NSTextField *l = [NSTextField labelWithString:text];
  l.font = [NSFont systemFontOfSize:11.0];
  l.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  l.alignment = NSTextAlignmentCenter;
  l.lineBreakMode = NSLineBreakByWordWrapping;
  l.translatesAutoresizingMaskIntoConstraints = NO;
  return l;
}

// One icon pill per category, in ShaderCategoryIDs() order. Multi-select (not
// radioMode): "generators and transitions" is a reasonable thing to ask for,
// and with nothing lit the filter is simply off.
//
// Icons rather than names: five localized words don't fit a 300pt inspector
// panel on one row, and the same symbols badge the cards, so the row doubles as
// the legend for them.
- (KKPillToggleRowView *)_buildCategoryPills {
  // Raw symbols, unconfigured: the pill row sizes its own glyphs. A nil from an
  // unknown symbol name would take the array literal down with it, so fall back
  // to a blank of the same footprint - a missing icon is a blemish, a crash on
  // an OS that never shipped one is not.
  NSMutableArray<NSImage *> *icons = [NSMutableArray array];
  NSMutableArray<NSNumber *> *states = [NSMutableArray array];
  for (NSString *c in ShaderCategoryIDs()) {
    NSImage *img =
        [NSImage imageWithSystemSymbolName:ShaderCategorySymbol(c)
                  accessibilityDescription:ShaderCategoryDisplayName(c)];
    [icons addObject:img ?: [[NSImage alloc] initWithSize:NSMakeSize(11, 11)]];
    [states addObject:@NO]; // nothing lit = filter off
  }
  KKPillToggleRowView *pills =
      [[KKPillToggleRowView alloc] initWithIcons:icons];
  pills.translatesAutoresizingMaskIntoConstraints = NO;
  pills.grouped = YES; // one segmented track, not five loose buttons
  pills.states = states;
  pills.toolTip = RLoc(@"Filter by type", @"Category filter row tooltip.");
  __weak typeof(self) weak = self;
  pills.onToggled = ^(NSInteger index, BOOL isOn) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    NSArray<NSString *> *ids = ShaderCategoryIDs();
    if (index < 0 || index >= (NSInteger)ids.count)
      return;
    if (isOn)
      [s->_categoryFilter addObject:ids[index]];
    else
      [s->_categoryFilter removeObject:ids[index]];
    [s _rebuildAll];
  };
  return pills;
}

- (NSImage *)_headerIcon:(NSString *)symbol {
  NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                           accessibilityDescription:nil];
  return [img imageWithSymbolConfiguration:
                  [NSImageSymbolConfiguration
                      configurationWithPointSize:12.0
                                          weight:NSFontWeightRegular]];
}

- (NSButton *)_headerToggle:(NSString *)symbol
                     action:(SEL)action
                    tooltip:(NSString *)tip {
  NSButton *b = [NSButton buttonWithImage:[self _headerIcon:symbol]
                                   target:self
                                   action:action];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.contentTintColor = [NSColor tertiaryLabelColor];
  b.toolTip = tip;
  return b;
}

- (void)reload {
  _fetching = YES; // show the inline loader until the fetch returns
  [self _rebuildAll];
  [self _fetchCommunity];
}

- (void)refreshLocal {
  [self _rebuildAll];
}

- (BOOL)_matches:(_ShaderBrowserItem *)it {
  if (_favoritesOnly && ![[ShaderLocalCatalog shared] isFavorite:it.entryID])
    return NO;
  // Normalised, so an entry whose category this build doesn't know filters as
  // the default rather than as nothing at all (it badges as the default too).
  if (_categoryFilter.count &&
      ![_categoryFilter containsObject:ShaderCategoryNormalize(it.category)])
    return NO;
  if (_query.length &&
      [it.name rangeOfString:_query options:NSCaseInsensitiveSearch].location ==
          NSNotFound)
    return NO;
  return YES;
}

- (void)_rebuildAll {
  // Never tear down cards while one is being renamed (destroying the active
  // field editor's view crashes); defer the rebuild until the edit ends.
  if (_renaming) {
    _needsRebuild = YES;
    return;
  }
  NSArray<ShaderCatalogEntry *> *saved = [[[ShaderLocalCatalog shared] entries]
      sortedArrayUsingComparator:^NSComparisonResult(ShaderCatalogEntry *a,
                                                     ShaderCatalogEntry *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
      }];

  // Split local: installed community (offline) vs user custom.
  NSMutableDictionary<NSString *, ShaderCatalogEntry *> *installedByID =
      [NSMutableDictionary dictionary];
  NSMutableArray<ShaderCatalogEntry *> *customLocal = [NSMutableArray array];
  for (ShaderCatalogEntry *e in saved) {
    if (e.community)
      installedByID[e.entryID] = e;
    else
      [customLocal addObject:e];
  }

  // Keyframeless = built-ins + community (installed offline + remote), merged.
  NSMutableArray<_ShaderBrowserItem *> *keyframeless = [NSMutableArray array];
  for (ShaderCatalogEntry *e in [[ShaderLocalCatalog shared] builtinEntries]) {
    _ShaderBrowserItem *it = [_ShaderBrowserItem new];
    it.kind = _ShaderItemBuiltin;
    it.entryID = e.entryID;
    it.name = e.name;
    it.author = e.author;
    it.category = e.category;
    it.thumbnail = e.thumbnail;
    it.localEntry = e;
    if ([self _matches:it])
      [keyframeless addObject:it];
  }
  NSMutableSet<NSString *> *mergedIDs = [NSMutableSet set];
  for (_ShaderBrowserItem *r in _community) {
    ShaderCatalogEntry *inst = installedByID[r.entryID];
    _ShaderBrowserItem *it = [_ShaderBrowserItem new];
    it.entryID = r.entryID;
    it.name = inst.name ?: r.name;
    it.author = inst.author ?: r.author;
    // An installed copy is the authority (it may be a newer publish than the
    // last fetch); otherwise the remote's.
    it.category = inst ? inst.category : r.category;
    it.communityEntry = r.communityEntry;
    if (inst) {
      it.kind = _ShaderItemInstalled;
      it.localEntry = inst;
      it.thumbnail = inst.thumbnail;
      it.updateAvailable = r.communityEntry.version > inst.version;
      [mergedIDs addObject:r.entryID];
    } else {
      it.kind = _ShaderItemRemote;
      it.thumbnail = _communityThumbnails[r.entryID];
    }
    if ([self _matches:it])
      [keyframeless addObject:it];
  }
  // Installed community not in the last fetch (offline) still show as
  // installed.
  for (NSString *entryID in installedByID) {
    if ([mergedIDs containsObject:entryID])
      continue;
    ShaderCatalogEntry *inst = installedByID[entryID];
    _ShaderBrowserItem *it = [_ShaderBrowserItem new];
    it.kind = _ShaderItemInstalled;
    it.entryID = entryID;
    it.name = inst.name;
    it.author = inst.author;
    it.category = inst.category;
    it.thumbnail = inst.thumbnail;
    it.localEntry = inst;
    if ([self _matches:it])
      [keyframeless addObject:it];
  }

  NSMutableArray<_ShaderBrowserItem *> *custom = [NSMutableArray array];
  for (ShaderCatalogEntry *e in customLocal) {
    _ShaderBrowserItem *it = [_ShaderBrowserItem new];
    it.kind = _ShaderItemLocal;
    it.entryID = e.entryID;
    it.name = e.name;
    it.author = e.author;
    it.category = e.category;
    it.thumbnail = e.thumbnail;
    it.localEntry = e;
    if ([self _matches:it])
      [custom addObject:it];
  }

  for (_ShaderCard *c in _cards)
    [c removeFromSuperview];
  for (NSView *v in [_doc.subviews copy])
    if (![v isKindOfClass:[_ShaderCard class]])
      [v removeFromSuperview];
  [_cards removeAllObjects];
  _hovered = nil;

  CGFloat width = NSWidth(_doc.bounds);
  if (width <= 0)
    width = NSWidth(_well.bounds);
  // Two columns that split the width 50/50 (cards fill, no big right margin).
  const NSInteger cols = 2;
  _cardW = floor((width - (cols + 1) * kCardGap) / cols);
  _cardH = round(_cardW * 9.0 / 16.0) + 3.0 + kShaderCardNameH;
  CGFloat leftPad = kCardGap;

  CGFloat y = kCardGap;
  y = [self _addSection:RLoc(@"Keyframeless", @"Built-in shaders section.")
                  items:keyframeless
                    atY:y
                   cols:cols
                leftPad:leftPad
                  width:width];
  // Spinner + text right after the last community card (Steno's placement).
  if (_fetching) {
    NSProgressIndicator *spin = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(leftPad, y, 14, 14)];
    spin.style = NSProgressIndicatorStyleSpinning;
    spin.controlSize = NSControlSizeSmall;
    [spin startAnimation:nil];
    [_doc addSubview:spin];
    NSTextField *load =
        [NSTextField labelWithString:RLoc(@"Loading community shaders…",
                                          @"Community loading.")];
    load.font = [NSFont systemFontOfSize:11.0];
    load.textColor = [NSColor secondaryLabelColor];
    load.frame = NSMakeRect(leftPad + 20, y, width - leftPad * 2 - 20, 15);
    [_doc addSubview:load];
    y += 24;
  }
  y = [self _addSection:RLoc(@"Custom", @"Custom shaders section.")
                  items:custom
                    atY:y
                   cols:cols
                leftPad:leftPad
                  width:width];

  // Grow the document to the laid-out card height. The scroll container reads
  // this via the doc's intrinsic size (it pins width + top, not height) and
  // updates its edge-fade shadows off the resulting scroll range.
  _doc.contentHeight = y;
  BOOL none = (keyframeless.count + custom.count) == 0 && !_fetching;
  _empty.hidden = !none;
  BOOL filtering = _query.length || _favoritesOnly || _categoryFilter.count;
  _empty.stringValue = filtering
                           ? RLoc(@"No matching shaders", @"No filter results.")
                           : RLoc(@"No shaders yet.", @"Empty browser state.");
}

- (CGFloat)_addSection:(NSString *)title
                 items:(NSArray<_ShaderBrowserItem *> *)items
                   atY:(CGFloat)y
                  cols:(NSInteger)cols
               leftPad:(CGFloat)leftPad
                 width:(CGFloat)width {
  if (!items.count)
    return y;
  NSTextField *header = [NSTextField labelWithString:title];
  header.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
  header.textColor = [NSColor secondaryLabelColor];
  header.frame = NSMakeRect(leftPad, y, width - leftPad * 2, kHeaderH - 4);
  [_doc addSubview:header];
  y += kHeaderH;

  for (NSUInteger i = 0; i < items.count; i++) {
    NSInteger col = i % cols, row = i / cols;
    _ShaderCard *card = [[_ShaderCard alloc] initWithItem:items[i]
                                                    width:_cardW];
    card.owner = self;
    card.frame = NSMakeRect(leftPad + col * (_cardW + kCardGap),
                            y + row * (_cardH + kCardGap), _cardW, _cardH);
    [_doc addSubview:card];
    [_cards addObject:card];
  }
  NSInteger rows = (items.count + cols - 1) / cols;
  return y + rows * (_cardH + kCardGap) + kCardGap;
}

- (void)_fetchCommunity {
  KKCommunityClient *client =
      [[KKCommunityClient alloc] initWithCatalogFolder:@"Shaders"];
  __weak typeof(self) weak = self;
  [client fetchEntriesWithCompletion:^(NSArray<KKCommunityEntry *> *entries,
                                       NSString *error) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_fetching = NO;
    NSMutableArray<_ShaderBrowserItem *> *items = [NSMutableArray array];
    for (KKCommunityEntry *e in entries) {
      _ShaderBrowserItem *it = [_ShaderBrowserItem new];
      it.entryID = e.entryID;
      it.name = e.name;
      it.author = e.author;
      // Straight out of the remote metadata.json: KKCommunityEntry carries the
      // raw values for payload-specific keys like this, so a category needs no
      // change on the KKCommunity (Swift) side.
      it.category = ShaderCategoryNormalize(e.metadata[@"category"]);
      it.communityEntry = e;
      [items addObject:it];
      [s _loadCommunityThumbnail:e];
    }
    s->_community = items;
    [s _rebuildAll];
  }];
}

- (void)_loadCommunityThumbnail:(KKCommunityEntry *)e {
  if (!e.previewURLString.length || _communityThumbnails[e.entryID])
    return;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSData *data =
        [NSData dataWithContentsOfURL:[NSURL URLWithString:e.previewURLString]];
    NSImage *img = data ? [[NSImage alloc] initWithData:data] : nil;
    if (!img)
      return;
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(weak) s = weak;
      s->_communityThumbnails[e.entryID] = img;
      for (_ShaderCard *c in s->_cards)
        if ([c.item.entryID isEqualToString:e.entryID] && !c.item.localEntry)
          [c setThumbnail:img];
    });
  });
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (_mouseMonitor) {
    [NSEvent removeMonitor:_mouseMonitor];
    _mouseMonitor = nil;
  }
  if (!self.window)
    return;
  __weak typeof(self) weak = self;
  _mouseMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                            handler:^NSEvent *(NSEvent *e) {
                                              [weak _updateHoverFromEvent:e];
                                              return e;
                                            }];
}

- (void)_updateHoverFromEvent:(NSEvent *)e {
  if (e.window != self.window)
    return;
  NSPoint inDoc = [_doc convertPoint:e.locationInWindow fromView:nil];
  _ShaderCard *hit = nil;
  for (_ShaderCard *c in _cards)
    if (NSPointInRect(inDoc, c.frame)) {
      hit = c;
      break;
    }
  if (hit != _hovered) {
    [_hovered setHovered:NO];
    [hit setHovered:YES];
    _hovered = hit;
  }
  // Every move, not just on entry: the author badge expands only while the
  // pointer is actually on it, which the card can't know from a bare BOOL.
  [hit setHoverPoint:[hit convertPoint:e.locationInWindow fromView:nil]];
}

- (void)controlTextDidChange:(NSNotification *)note {
  if (note.object == _search) {
    _query = _search.stringValue ?: @"";
    [self _rebuildAll];
  }
}

// Caret/selection tint is applied in _ShaderSearchField becomeFirstResponder
// (sync + next tick) so it shows from the first frame, not after the first key.

// Esc / Enter drop focus (blur), matching the shader name field.
- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)selector {
  if (control != _search)
    return NO;
  if (selector == @selector(insertNewline:) ||
      selector == @selector(cancelOperation:)) {
    [_search.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

- (void)_refresh:(id)sender {
  _communityThumbnails = [NSMutableDictionary dictionary];
  [self reload]; // re-fetch the community list
}

- (void)_toggleFavFilter:(id)sender {
  _favoritesOnly = !_favoritesOnly;
  _favFilter.contentTintColor =
      _favoritesOnly ? [NSColor warning] : [NSColor tertiaryLabelColor];
  _favFilter.image =
      [self _headerIcon:(_favoritesOnly ? @"star.fill" : @"star")];
  [self _rebuildAll];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (_mouseMonitor)
    [NSEvent removeMonitor:_mouseMonitor];
  if (_searchOutsideClickMon)
    [NSEvent removeMonitor:_searchOutsideClickMon];
}

- (void)cardClicked:(_ShaderCard *)card {
  if (self.onSelectEntry && card.item.localEntry)
    self.onSelectEntry(card.item.localEntry);
}
- (void)cardPublish:(_ShaderCard *)card {
  if (self.onPublishEntry && card.item.localEntry)
    self.onPublishEntry(card.item.localEntry);
}
- (void)cardDelete:(_ShaderCard *)card {
  if (self.onDeleteEntry && card.item.localEntry)
    self.onDeleteEntry(card.item.localEntry);
}
- (void)cardRename:(_ShaderCard *)card toName:(NSString *)name {
  if (self.onRenameEntry && card.item.localEntry)
    self.onRenameEntry(card.item.localEntry, name);
}
- (void)cardToggleFavorite:(_ShaderCard *)card {
  [[ShaderLocalCatalog shared] toggleFavorite:card.item.entryID];
  [self _rebuildAll];
}
- (void)card:(_ShaderCard *)card didBeginRename:(BOOL)renaming {
  _renaming = renaming;
  if (!renaming && _needsRebuild) {
    _needsRebuild = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self _rebuildAll];
    });
  }
}
// Download = install the community shader locally for offline use (a
// re-download updates it, keyed by community id). It stays a community shader
// (not Custom), so it can only be uninstalled or updated, never re-published.
- (void)cardDownload:(_ShaderCard *)card {
  KKCommunityEntry *e = card.item.communityEntry;
  if (!e)
    return;
  KKCommunityClient *client =
      [[KKCommunityClient alloc] initWithCatalogFolder:@"Shaders"];
  __weak typeof(self) weak = self;
  [client downloadFiles:e
             completion:^(NSDictionary<NSString *, NSData *> *files,
                          NSString *error) {
               if (!files)
                 return;
               NSMutableDictionary<NSString *, NSString *> *sections =
                   [NSMutableDictionary dictionary];
               // The preview is whatever the entry's metadata names
               // (preview.jpg now, preview.png for anything published before
               // the switch), so a hard-coded filename can't miss it.
               NSString *previewName = e.metadata[@"preview"] ?: @"preview.jpg";
               NSData *preview = nil;
               for (NSString *file in files) {
                 if ([file isEqualToString:previewName]) {
                   preview = files[file];
                   continue;
                 }
                 NSString *section = ShaderSectionNameForFile(file);
                 NSString *code =
                     [[NSString alloc] initWithData:files[file]
                                           encoding:NSUTF8StringEncoding];
                 if (section && code)
                   sections[section] = code;
               }
               // Raw, not normalised: a shader published by a newer build keeps
               // the category it was published with (see -installCommunityID:).
               [[ShaderLocalCatalog shared]
                   installCommunityID:e.entryID
                                 name:e.name
                               author:e.author
                             category:e.metadata[@"category"]
                              version:e.version
                             sections:sections
                          previewJPEG:preview];
               [weak _rebuildAll];
             }];
}

@end
