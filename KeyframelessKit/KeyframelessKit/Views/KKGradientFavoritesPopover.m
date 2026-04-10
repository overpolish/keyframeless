/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKGradientFavoritesPopover.h"
#import "KKGradientFavorites.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

static const CGFloat kPopoverWidth = 240.0;
static const CGFloat kRowHeight = 28.0;
static const CGFloat kPreviewHeight = 12.0;
static const CGFloat kPreviewWidth = 50.0;
static const CGFloat kSaveRowHeight = 32.0;
static const CGFloat kEmptyRowHeight = 28.0;
static const CGFloat kMaxVisibleRows = 7;

static void _clearPopoverBackground(NSView *view) {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSView *current = view;
        NSView *popoverFrame = nil;
        while (current) {
          if ([NSStringFromClass([current class])
                  hasPrefix:@"NSPopoverFrame"]) {
            popoverFrame = current;
            break;
          }
          current = current.superview;
        }
        if (!popoverFrame)
          return;
        for (NSView *sub in popoverFrame.subviews) {
          if (![NSStringFromClass([sub class]) containsString:@"GlassView"])
            continue;
          for (NSView *glassSub in sub.subviews) {
            glassSub.wantsLayer = YES;
            NSString *name = NSStringFromClass([glassSub class]);
            if ([name containsString:@"CoreHostingView"])
              glassSub.layer.opacity = 0;
            else if ([name containsString:@"ContentHolderView"])
              glassSub.layer.backgroundColor = NSColor.clearColor.CGColor;
          }
          break;
        }
      });
}

@interface KKGradientMiniBar : NSView
@property(nonatomic, copy) NSArray<KKGradientStop *> *stops;
@property(nonatomic, copy) void (^onTap)(void);
@end

@implementation KKGradientMiniBar

- (void)drawRect:(NSRect)dirtyRect {
  NSArray<KKGradientStop *> *sorted = [_stops
      sortedArrayUsingComparator:^(KKGradientStop *a, KKGradientStop *b) {
        if (a.position < b.position)
          return NSOrderedAscending;
        if (a.position > b.position)
          return NSOrderedDescending;
        return NSOrderedSame;
      }];
  if (sorted.count < 2)
    return;

  NSMutableArray<NSColor *> *colors = [NSMutableArray new];
  NSMutableArray<NSNumber *> *locs = [NSMutableArray new];
  for (NSUInteger i = 0; i < sorted.count; i++) {
    [colors addObject:sorted[i].color];
    [locs addObject:@(sorted[i].position)];
    if (i < sorted.count - 1) {
      CGFloat m = sorted[i].midpoint;
      CGFloat midPos = sorted[i].position +
                       m * (sorted[i + 1].position - sorted[i].position);
      NSColor *midColor =
          [sorted[i].color blendedColorWithFraction:0.5
                                            ofColor:sorted[i + 1].color];
      [colors addObject:midColor];
      [locs addObject:@(midPos)];
    }
  }
  CGFloat *locations = malloc(sizeof(CGFloat) * locs.count);
  for (NSUInteger i = 0; i < locs.count; i++)
    locations[i] = locs[i].doubleValue;

  NSGradient *gradient =
      [[NSGradient alloc] initWithColors:colors
                             atLocations:locations
                              colorSpace:[NSColorSpace sRGBColorSpace]];
  free(locations);

  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                       xRadius:KKRadiusSM
                                                       yRadius:KKRadiusSM];
  [gradient drawInBezierPath:path angle:0];

  [[NSColor.inspectorLabel colorWithAlphaComponent:0.2] setStroke];
  NSBezierPath *border =
      [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                      xRadius:KKRadiusSM
                                      yRadius:KKRadiusSM];
  border.lineWidth = KKBorderWidthXS;
  [border stroke];
}

- (void)mouseDown:(NSEvent *)event {
  if (_onTap)
    _onTap();
}

@end

@interface KKGradientFavoriteRowView : NSView <NSTextFieldDelegate>
@property(nonatomic, strong) KKGradientFavorite *favorite;
@property(nonatomic, copy) void (^onDelete)(NSString *identifier);
@property(nonatomic, copy) void (^onRename)
    (NSString *identifier, NSString *newName);
@property(nonatomic, copy) void (^onSelect)(NSArray<KKGradientStop *> *stops);
@end

@implementation KKGradientFavoriteRowView {
  KKGradientMiniBar *_preview;
  NSTextField *_nameField;
  NSButton *_deleteButton;
}

- (instancetype)initWithFavorite:(KKGradientFavorite *)favorite {
  self = [super initWithFrame:NSMakeRect(0, 0, kPopoverWidth, kRowHeight)];
  if (self) {
    _favorite = favorite;

    _preview = [[KKGradientMiniBar alloc] initWithFrame:NSZeroRect];
    _preview.stops = favorite.stops;
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_preview];

    __weak typeof(self) weakSelf = self;
    _preview.onTap = ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf && strongSelf.onSelect)
        strongSelf.onSelect(strongSelf.favorite.stops);
    };

    _nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _nameField.stringValue = favorite.name;
    _nameField.font = [NSFont systemFontOfSize:11.0];
    _nameField.textColor = [NSColor inspectorLabel];
    _nameField.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameField.translatesAutoresizingMaskIntoConstraints = NO;
    _nameField.editable = NO;
    _nameField.selectable = NO;
    _nameField.bordered = NO;
    _nameField.bezeled = NO;
    _nameField.drawsBackground = NO;
    _nameField.focusRingType = NSFocusRingTypeNone;
    _nameField.delegate = self;
    _nameField.cell.scrollable = YES;
    _nameField.cell.wraps = NO;
    [self addSubview:_nameField];

    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
        configurationWithPointSize:10.0
                            weight:NSFontWeightRegular];
    NSImage *xImg = [[NSImage imageWithSystemSymbolName:@"trash"
                               accessibilityDescription:@"Delete"]
        imageWithSymbolConfiguration:cfg];
    _deleteButton = [NSButton buttonWithImage:xImg
                                       target:self
                                       action:@selector(_deleteTapped:)];
    _deleteButton.bordered = NO;
    _deleteButton.contentTintColor =
        [NSColor.inspectorLabel colorWithAlphaComponent:0.4];
    _deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_deleteButton];

    [NSLayoutConstraint activateConstraints:@[
      [_preview.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:KKPaddingLG],
      [_preview.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_preview.widthAnchor constraintEqualToConstant:kPreviewWidth],
      [_preview.heightAnchor constraintEqualToConstant:kPreviewHeight],

      [_nameField.leadingAnchor constraintEqualToAnchor:_preview.trailingAnchor
                                               constant:KKSpacingLG],
      [_nameField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_nameField.trailingAnchor
          constraintLessThanOrEqualToAnchor:_deleteButton.leadingAnchor
                                   constant:-KKSpacingSM],

      [_deleteButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                   constant:-KKPaddingLG],
      [_deleteButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_deleteButton.widthAnchor constraintEqualToConstant:16.0],
      [_deleteButton.heightAnchor constraintEqualToConstant:16.0],
    ]];
  }
  return self;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (NSPointInRect(point, _nameField.frame) && event.clickCount == 2) {
    _nameField.editable = YES;
    _nameField.selectable = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.window makeKeyAndOrderFront:nil];
      [self.window makeFirstResponder:self->_nameField];
      self->_nameField.currentEditor.selectedRange =
          NSMakeRange(0, self->_nameField.stringValue.length);
    });
    return;
  }
  [super mouseDown:event];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
  _nameField.editable = NO;
  _nameField.selectable = NO;
  NSString *newName = [_nameField.stringValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (newName.length > 0 && _onRename)
    _onRename(_favorite.identifier, newName);
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (commandSelector == @selector(insertNewline:)) {
    [self.window makeFirstResponder:nil];
    return YES;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    _nameField.stringValue = _favorite.name;
    _nameField.editable = NO;
    _nameField.selectable = NO;
    [self.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

- (void)_deleteTapped:(id)sender {
  if (_onDelete)
    _onDelete(_favorite.identifier);
}

@end

@interface KKGradientFavoritesContentView : NSView
@end

@implementation KKGradientFavoritesContentView

- (BOOL)isFlipped {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window)
    _clearPopoverBackground(self);
}

@end

@interface KKGradientFavoritesPopover () <NSPopoverDelegate,
                                          NSTextFieldDelegate>
@end

@implementation KKGradientFavoritesPopover {
  NSPopover *_popover;
  NSTextField *_saveNameField;
  __weak NSView *_anchorView;
  NSRect _anchorRect;
}

- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view {
  if (_popover.isShown) {
    [_popover close];
    return;
  }

  _anchorView = view;
  _anchorRect = rect;

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = [self _buildContent];

  _popover = [[NSPopover alloc] init];
  _popover.contentViewController = vc;
  _popover.behavior = NSPopoverBehaviorTransient;
  _popover.delegate = self;
  [_popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMinY];
}

- (NSView *)_buildContent {
  NSArray<KKGradientFavorite *> *favorites =
      [[KKGradientFavorites shared] favorites];

  CGFloat listHeight = favorites.count * kRowHeight;
  CGFloat maxListHeight = kMaxVisibleRows * kRowHeight;
  CGFloat clippedListHeight = fmin(listHeight, maxListHeight);
  BOOL needsScroll = listHeight > maxListHeight;
  BOOL hasItems = favorites.count > 0;
  CGFloat emptyHeight = hasItems ? 0 : kEmptyRowHeight;
  CGFloat totalHeight = (hasItems ? clippedListHeight : emptyHeight) +
                        kSaveRowHeight + KKSpacingSM;

  KKGradientFavoritesContentView *content =
      [[KKGradientFavoritesContentView alloc]
          initWithFrame:NSMakeRect(0, 0, kPopoverWidth, totalHeight)];

  CGFloat y = 0;

  if (hasItems) {
    NSView *listContainer = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, kPopoverWidth, listHeight)];
    listContainer.autoresizesSubviews = NO;
    CGFloat rowY = 0;
    for (KKGradientFavorite *fav in favorites) {
      KKGradientFavoriteRowView *row =
          [[KKGradientFavoriteRowView alloc] initWithFavorite:fav];
      row.frame = NSMakeRect(0, rowY, kPopoverWidth, kRowHeight);
      row.autoresizingMask = NSViewWidthSizable;

      __weak typeof(self) weakSelf = self;

      row.onSelect = ^(NSArray<KKGradientStop *> *stops) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
          return;
        if (strongSelf->_popover)
          [strongSelf->_popover close];
        if (strongSelf.onApplyFavorite)
          strongSelf.onApplyFavorite(stops);
      };

      row.onDelete = ^(NSString *identifier) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
          return;
        [[KKGradientFavorites shared] removeFavoriteWithIdentifier:identifier];
        [strongSelf _rebuildPopover];
      };

      row.onRename = ^(NSString *identifier, NSString *newName) {
        [[KKGradientFavorites shared] renameFavoriteWithIdentifier:identifier
                                                            toName:newName];
      };

      [listContainer addSubview:row];
      rowY += kRowHeight;
    }

    if (needsScroll) {
      NSScrollView *scroll = [[NSScrollView alloc]
          initWithFrame:NSMakeRect(0, 0, kPopoverWidth, clippedListHeight)];
      scroll.documentView = listContainer;
      scroll.hasVerticalScroller = YES;
      scroll.autohidesScrollers = YES;
      scroll.drawsBackground = NO;
      [content addSubview:scroll];
      y = clippedListHeight;
    } else {
      listContainer.frame = NSMakeRect(0, 0, kPopoverWidth, clippedListHeight);
      [content addSubview:listContainer];
      y = clippedListHeight;
    }
  } else {
    NSTextField *emptyLabel =
        [NSTextField labelWithString:@"No favorites saved"];
    emptyLabel.font = [NSFont systemFontOfSize:11.0];
    emptyLabel.textColor = [NSColor.inspectorLabel colorWithAlphaComponent:0.4];
    emptyLabel.alignment = NSTextAlignmentCenter;
    emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
      [emptyLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
      [emptyLabel.trailingAnchor
          constraintEqualToAnchor:content.trailingAnchor],
      [emptyLabel.centerYAnchor constraintEqualToAnchor:content.topAnchor
                                               constant:kEmptyRowHeight * 0.5],
    ]];
    y = kEmptyRowHeight;
  }

  NSBox *separator = [[NSBox alloc]
      initWithFrame:NSMakeRect(KKPaddingLG, y, kPopoverWidth - KKPaddingLG * 2,
                               1)];
  separator.boxType = NSBoxSeparator;
  [content addSubview:separator];
  y += KKSpacingSM;

  NSView *saveRow = [[NSView alloc]
      initWithFrame:NSMakeRect(0, y, kPopoverWidth, kSaveRowHeight)];

  NSTextField *nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
  nameField.placeholderString = @"Name";
  nameField.font = [NSFont systemFontOfSize:11.0];
  nameField.textColor = [NSColor inspectorLabel];
  nameField.bezeled = YES;
  nameField.bezelStyle = NSTextFieldRoundedBezel;
  nameField.translatesAutoresizingMaskIntoConstraints = NO;
  nameField.delegate = self;
  [saveRow addSubview:nameField];

  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:11.0
                          weight:NSFontWeightMedium];
  NSImage *plusImg = [[NSImage imageWithSystemSymbolName:@"plus"
                                accessibilityDescription:@"Save"]
      imageWithSymbolConfiguration:cfg];
  NSButton *saveBtn = [NSButton buttonWithImage:plusImg
                                         target:self
                                         action:@selector(_saveTapped:)];
  saveBtn.bordered = NO;
  saveBtn.contentTintColor = [NSColor inspectorLabel];
  saveBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [saveRow addSubview:saveBtn];

  [NSLayoutConstraint activateConstraints:@[
    [nameField.leadingAnchor constraintEqualToAnchor:saveRow.leadingAnchor
                                            constant:KKPaddingLG],
    [nameField.centerYAnchor constraintEqualToAnchor:saveRow.centerYAnchor],
    [nameField.trailingAnchor constraintEqualToAnchor:saveBtn.leadingAnchor
                                             constant:-KKSpacingSM],

    [saveBtn.trailingAnchor constraintEqualToAnchor:saveRow.trailingAnchor
                                           constant:-KKPaddingLG],
    [saveBtn.centerYAnchor constraintEqualToAnchor:saveRow.centerYAnchor],
    [saveBtn.widthAnchor constraintEqualToConstant:20.0],
    [saveBtn.heightAnchor constraintEqualToConstant:20.0],
  ]];

  [content addSubview:saveRow];

  _saveNameField = nameField;

  return content;
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (control == _saveNameField &&
      commandSelector == @selector(insertNewline:)) {
    [self _saveTapped:nil];
    return YES;
  }
  return NO;
}

- (void)_saveTapped:(NSButton *)sender {
  NSString *name = [_saveNameField.stringValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (name.length == 0 || _currentStops.count < 2)
    return;

  [[KKGradientFavorites shared] addFavoriteWithName:name stops:_currentStops];
  [self _rebuildPopover];
}

- (void)_rebuildPopover {
  if (!_popover.isShown || !_anchorView)
    return;
  [_popover close];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = [self _buildContent];

  _popover = [[NSPopover alloc] init];
  _popover.contentViewController = vc;
  _popover.behavior = NSPopoverBehaviorTransient;
  _popover.delegate = self;
  [_popover showRelativeToRect:_anchorRect
                        ofView:_anchorView
                 preferredEdge:NSRectEdgeMinY];
}

- (void)popoverDidClose:(NSNotification *)notification {
  _popover = nil;
}

@end
