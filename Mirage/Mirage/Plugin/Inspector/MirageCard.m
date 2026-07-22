/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageBrowserInternal.h"

#import "MirageBadgeView.h"
#import "MirageCategory.h"
#import "MirageLocalCatalog.h"
#import "MirageLocalized.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>

const CGFloat kMirageCardNameH = 16.0;

@implementation _MirageCard {
  NSImageView *_thumb;
  NSTextField *_name;
  NSMutableArray<NSButton *> *_hoverButtons; // delete + primary (hover-only)
  NSButton *_favButton;
  BOOL _hovered;
  CGFloat _w, _imgH;  // card width + thumbnail height (16:9), set per rebuild
  id _keyMonitor;     // forwards keyDown to the rename field editor
  id _renameClickMon; // blurs the rename field on a click outside it
  NSString
      *_typeTooltip; // the type badge's rect tooltip (see -addToolTipRect:)
  _MirageBadge *_authorBadge; // nil when the shader names no author
}

- (instancetype)initWithItem:(_MirageBrowserItem *)item width:(CGFloat)width {
  CGFloat imgH = round(width * 9.0 / 16.0);
  self = [super
      initWithFrame:NSMakeRect(0, 0, width, imgH + 3.0 + kMirageCardNameH)];
  if (!self)
    return nil;
  _item = item;
  _w = width;
  _imgH = imgH;
  _favorite = [[MirageLocalCatalog shared] isFavorite:item.entryID];

  _thumb = [[NSImageView alloc]
      initWithFrame:NSMakeRect(0, kMirageCardNameH + 3.0, _w, _imgH)];
  _thumb.imageScaling = NSImageScaleProportionallyUpOrDown;
  _thumb.wantsLayer = YES;
  _thumb.layer.cornerRadius = KKRadiusMD;
  _thumb.layer.masksToBounds = YES;
  _thumb.layer.backgroundColor =
      [NSColor colorWithWhite:0.0 alpha:0.25].CGColor;
  _thumb.image = item.thumbnail;
  [self addSubview:_thumb];

  // Author (right end of the name row), when the shader names one. Built before
  // the name field so the name can give way to it - the name row is also the
  // rename hit region, so overlapping them would make a click near the author
  // start an edit. It is ADDED after the name, though: expanding it on hover
  // has it grow left across the name, and it has to draw on top to do that.
  //
  // Clamped to a third of the card, because the shader's own name is what
  // people scan for; the full author is a hover away.
  if (item.author.length) {
    // The tint has to be OPAQUE: expanding grows the capsule left across the
    // name (see below), and a 15% translucent fill let the title bleed through,
    // reading as if the badge sat under it. Bake the same 15% accent onto the
    // card's own background so it still looks like a light accent chip, but now
    // occludes what it slides over.
    NSColor *authorFill = [[NSColor controlBackgroundColor]
        blendedColorWithFraction:0.15
                         ofColor:[NSColor accentMatchingHost]];
    _authorBadge =
        [[_MirageBadge alloc] initWithSymbol:@"person.fill"
                                        text:item.author
                                       color:[NSColor accentMatchingHost]
                                        fill:authorFill
                                    maxWidth:floor(_w / 3.0)];
    NSRect af = _authorBadge.frame;
    af.origin = NSMakePoint(_w - 1 - NSWidth(af),
                            round((kMirageCardNameH - NSHeight(af)) / 2.0));
    _authorBadge.frame = af;
  }

  CGFloat nameW =
      _w - 2 - (_authorBadge ? NSWidth(_authorBadge.frame) + KKSpacingSM : 0.0);
  _name = [[_MirageRenameField alloc]
      initWithFrame:NSMakeRect(1, 0, nameW, kMirageCardNameH)];
  _name.editable = NO;
  _name.selectable = NO;
  _name.bordered = NO;
  _name.bezeled = NO;
  _name.drawsBackground = NO;
  _name.stringValue = item.name ?: @"";
  _name.font = [NSFont systemFontOfSize:10.5];
  _name.alignment = NSTextAlignmentLeft;
  _name.lineBreakMode = NSLineBreakByTruncatingTail;
  _name.textColor = [NSColor secondaryLabelColor];
  _name.focusRingType = NSFocusRingTypeNone;
  [self addSubview:_name];
  if (_authorBadge)
    [self addSubview:_authorBadge]; // above the name: see the comment above

  // Type (top-centre, over the thumbnail): always shown, so the catalogue can
  // be read at a glance now that it holds every kind of shader. Icon only -
  // five localized words don't fit a card this size, and the header's filter
  // pills use the same symbols, so the row doubles as the legend.
  //
  // A dark scrim rather than InfoBadge's 15% tint: this one sits on a shader
  // render, which is routinely bright and saturated, and a tint that low
  // disappears against it.
  NSString *category = MirageCategoryNormalize(item.category);
  _MirageBadge *type = [[_MirageBadge alloc]
      initWithSymbol:MirageCategorySymbol(category)
                text:nil
               color:[NSColor colorWithWhite:1.0 alpha:0.9]
                fill:[NSColor colorWithWhite:0.0 alpha:0.45]
            maxWidth:0.0]; // icon only: nothing to clamp
  NSRect tf = type.frame;
  tf.origin =
      NSMakePoint(round((_w - NSWidth(tf)) / 2.0),
                  _imgH - NSHeight(tf) - KKPaddingMD + kMirageCardNameH + 3.0);
  type.frame = tf;
  [self addSubview:type];
  // The badge is click-through and the card collapses every non-button hit to
  // itself, so the badge can't carry its own tooltip - and an icon with no
  // tooltip is a rebus. Register the rect on the card instead.
  [self addToolTipRect:tf owner:self userData:NULL];
  _typeTooltip = MirageCategoryDisplayName(category);

  // Favourite (top-right): visible when favourited, else on hover. Right edge
  // aligned with the bottom-right action (same inset) so they line up.
  _favButton = [self _iconFor:(_favorite ? @"star.fill" : @"star")
                        point:11.0
                        color:(_favorite ? [NSColor warning]
                                         : [NSColor secondaryLabelColor])action
                             :@selector(_toggleFav:)
                      tooltip:RLoc(@"Favourite", @"Favourite tooltip.")];
  _favButton.frame =
      NSMakeRect(_w - 18 - KKPaddingMD,
                 _imgH - 18 - KKPaddingMD + kMirageCardNameH + 3, 18, 18);
  _favButton.hidden = !_favorite;
  [self addSubview:_favButton];

  // Delete (top-left) + primary action (bottom-right), hover-only. Added
  // directly to the card (not a covering container) so hit-testing reaches each
  // button + the favourite. Frames are thumb-relative (offset by the name row).
  const CGFloat topY = _imgH - 18 - KKPaddingMD + kMirageCardNameH + 3;
  const CGFloat botY = KKPaddingMD + kMirageCardNameH + 3;
  _hoverButtons = [NSMutableArray array];
  NSButton * (^del)(NSString *) = ^NSButton *(NSString *tip) {
    NSButton *b = [self _iconFor:@"xmark.circle.fill"
                           point:12.0
                           color:[NSColor secondaryLabelColor]
                          action:@selector(_delete:)
                         tooltip:tip];
    b.frame = NSMakeRect(KKPaddingMD, topY, 18, 18);
    return b;
  };
  if (item.kind == _MirageItemLocal) {
    [_hoverButtons addObject:del(RLoc(@"Delete", @"Delete tooltip."))];
    NSButton *pub = [self _iconFor:@"arrow.up.circle.fill"
                             point:12.0
                             color:[NSColor secondaryLabelColor]
                            action:@selector(_publish:)
                           tooltip:RLoc(@"Publish", @"Publish tooltip.")];
    pub.frame = NSMakeRect(_w - 18 - KKPaddingMD, botY, 18, 18);
    [_hoverButtons addObject:pub];
  } else if (item.kind == _MirageItemInstalled) {
    [_hoverButtons addObject:del(RLoc(@"Uninstall", @"Uninstall tooltip."))];
    if (item.updateAvailable) {
      NSButton *up = [self _iconFor:@"arrow.down.circle.fill"
                              point:16.0
                              color:[NSColor accentMatchingHost]
                             action:@selector(_download:)
                            tooltip:RLoc(@"Update", @"Update tooltip.")];
      up.frame = NSMakeRect(_w - 22 - KKPaddingMD, botY, 22, 22);
      [_hoverButtons addObject:up];
    }
  } else if (item.kind == _MirageItemRemote) {
    NSButton *dl = [self _iconFor:@"arrow.down.circle.fill"
                            point:16.0
                            color:[NSColor accentMatchingHost]
                           action:@selector(_download:)
                          tooltip:RLoc(@"Download", @"Download tooltip.")];
    dl.frame = NSMakeRect(_w - 22 - KKPaddingMD, botY, 22, 22);
    [_hoverButtons addObject:dl];
  }
  for (NSButton *b in _hoverButtons) {
    b.hidden = YES;
    [self addSubview:b];
  }
  return self;
}

- (NSButton *)_iconFor:(NSString *)symbol
                 point:(CGFloat)pt
                 color:(NSColor *)color
                action:(SEL)action
               tooltip:(NSString *)tip {
  NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                           accessibilityDescription:tip];
  img = [img imageWithSymbolConfiguration:
                 [NSImageSymbolConfiguration
                     configurationWithPointSize:pt
                                         weight:NSFontWeightRegular]];
  NSButton *b = [NSButton buttonWithImage:img target:self action:action];
  b.bordered = NO;
  b.contentTintColor = color;
  b.toolTip = tip;
  b.imagePosition = NSImageOnly;
  return b;
}

- (void)setHovered:(BOOL)hovered {
  _hovered = hovered;
  for (NSButton *b in _hoverButtons)
    b.hidden = !hovered;
  _favButton.hidden = !(_favorite || hovered);
  if (!hovered)
    [_authorBadge setExpanded:NO animated:YES];
}

- (void)setHoverPoint:(NSPoint)point {
  // Tested against the badge's CURRENT frame, so once it has grown the pointer
  // can follow it left across the revealed name without it snapping shut. It
  // only collapses on leaving the expanded badge (or the card entirely).
  [_authorBadge setExpanded:NSPointInRect(point, _authorBadge.frame)
                   animated:YES];
}

- (void)setThumbnail:(NSImage *)image {
  _thumb.image = image;
}

- (void)_toggleFav:(id)sender {
  [_owner cardToggleFavorite:self];
}
- (void)_publish:(id)sender {
  [_owner cardPublish:self];
}
- (void)_delete:(id)sender {
  // Uninstalling a downloaded community shader is re-downloadable, so no
  // confirmation. Deleting a local (custom) shader is destructive - pop a small
  // confirmation menu from the button; dismissing it (click away / Esc)
  // cancels.
  if (_item.kind != _MirageItemLocal) {
    [_owner cardDelete:self];
    return;
  }
  NSMenu *menu = [[NSMenu alloc] init];
  menu.autoenablesItems = NO;
  NSString *title = [NSString
      stringWithFormat:RLoc(
                           @"Delete “%@”",
                           @"Delete-confirm menu item; %@ is the shader name."),
                       _item.name ?: @""];
  NSMenuItem *confirm =
      [[NSMenuItem alloc] initWithTitle:title
                                 action:@selector(_confirmDelete:)
                          keyEquivalent:@""];
  confirm.target = self;
  confirm.attributedTitle = [[NSAttributedString alloc]
      initWithString:title
          attributes:@{NSForegroundColorAttributeName : [NSColor error]}];
  if (@available(macOS 11.0, *)) {
    NSImage *trash = [NSImage imageWithSystemSymbolName:@"trash"
                               accessibilityDescription:nil];
    if (@available(macOS 12.0, *))
      trash =
          [trash imageWithSymbolConfiguration:
                     [NSImageSymbolConfiguration
                         configurationWithHierarchicalColor:[NSColor error]]];
    confirm.image = trash;
  }
  [menu addItem:confirm];
  NSMenuItem *cancel =
      [[NSMenuItem alloc] initWithTitle:RLoc(@"Cancel", @"Cancel menu item.")
                                 action:@selector(_cancelDelete:)
                          keyEquivalent:@""];
  cancel.target = self;
  [menu addItem:cancel];
  NSButton *b = sender;
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0, NSHeight(b.bounds) + 2)
                          inView:b];
}
- (void)_cancelDelete:(id)sender {
}
- (void)_confirmDelete:(id)sender {
  // Defer past the menu's modal tracking loop: cardDelete rebuilds the grid and
  // frees this card, and _delete: is still on the stack inside popUpMenu... so
  // deleting synchronously would use-after-free.
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    if (s)
      [s->_owner cardDelete:s];
  });
}
- (void)_download:(id)sender {
  [_owner cardDownload:self];
}

// The browser lives in a non-activating panel; without this a body click just
// brings the panel forward and never reaches mouseDown (so apply did nothing).
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

// The thumbnail image view + name label cover the card and would swallow a body
// click (their mouseDown is a no-op), so the card never got it. Route clicks on
// them to the card (apply / double-click rename); keep buttons + the live
// rename field working.
- (NSString *)view:(NSView *)view
    stringForToolTip:(NSToolTipTag)tag
               point:(NSPoint)point
            userData:(void *)data {
  return _typeTooltip ?: @"";
}

- (NSView *)hitTest:(NSPoint)point {
  NSView *hit = [super hitTest:point];
  if (!hit)
    return nil;
  if ([hit isKindOfClass:[NSButton class]])
    return hit;
  if (hit == _name && _name.isEditable)
    return hit;
  return self;
}

- (void)mouseDown:(NSEvent *)event {
  // Take key SYNCHRONOUSLY while handling the click (the panel is a
  // nonactivating child window - establishing key during a mouse-down in the
  // window is what actually makes it the real OS key window; doing it later in
  // a dispatch_async doesn't take, so keystrokes go to the host and the rename
  // field never types). Same as the Canvas layer list's selectIndex.
  [self.window makeKeyWindow];

  // The name row is its OWN control (inline rename), not part of the
  // thumbnail's click-to-apply / download hit region. A single click on the
  // name would otherwise fire cardClicked -> apply -> reload, which reloads the
  // shader and destabilises the card mid-rename (the first click of the rename
  // double-click). So a click on the name never applies; a double-click there
  // (local shaders only) begins the rename.
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  if (NSPointInRect(p, _name.frame)) {
    if (event.clickCount == 2 && _item.kind == _MirageItemLocal)
      [self _beginRename];
    return;
  }

  if (_item.kind == _MirageItemRemote) {
    [_owner cardDownload:self]; // not installed yet: a click downloads it
    return;
  }
  [_owner cardClicked:self]; // built-in / custom / installed: apply
}

// Inline rename, mirroring the Canvas layer list: focus on the next tick after
// making the window key, commit deferred, reset the I-beam cursor after.
- (void)_beginRename {
  // Inline + unstyled, exactly like the Canvas layer-list rename field.
  _name.editable = YES;
  _name.selectable = YES;
  _name.bordered = NO;
  _name.bezeled = NO;
  _name.drawsBackground = NO;
  _name.backgroundColor = [NSColor clearColor];
  _name.textColor = [NSColor labelColor];
  [_owner card:self didBeginRename:YES];

  // Delete/Backspace don't reach the field editor on their own in this panel;
  // forward just those. Letters type via the normal key path.
  __weak typeof(self) weak = self;
  if (!_keyMonitor) {
    _keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *e) {
                                       __strong typeof(weak) s = weak;
                                       if (!s || e.window != s.window)
                                         return e;
                                       NSText *editor = s->_name.currentEditor;
                                       if (!editor)
                                         return e;
                                       if (e.keyCode == 51 ||
                                           e.keyCode ==
                                               117) { // Delete / Fwd-Del
                                         [editor keyDown:e];
                                         return nil;
                                       }
                                       return e;
                                     }];
  }

  // A click outside the field (another card, empty space, the popover) drops
  // focus -> ends editing -> commit. The panel won't resign the field on its
  // own.
  if (!_renameClickMon)
    _renameClickMon = KKMakeFieldOutsideClickMonitor(_name);

  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s.window makeKeyWindow];
    [s.window makeFirstResponder:s->_name];
    [s->_name selectText:nil];
    // Set the delegate AFTER focus is established - matching Canvas. Setting it
    // before focus means the spurious begin/end-editing that fires while the
    // field takes focus hits our controlTextDidEndEditing, which commits and
    // ENDS the rename before the user can type a single character (and tears
    // down the key monitor). That was the whole "typing does nothing" bug.
    s->_name.delegate = s;
    // controlTextDidBeginEditing won't fire now (editing already began), so
    // tint the caret + selection directly.
    NSText *ed = s->_name.currentEditor;
    if ([ed isKindOfClass:[NSTextView class]]) {
      NSColor *accent = [NSColor accentMatchingHost];
      [(NSTextView *)ed setInsertionPointColor:accent];
      [(NSTextView *)ed setSelectedTextAttributes:@{
        NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
        NSForegroundColorAttributeName : [NSColor labelColor],
      }];
    }
  });
}

- (void)_removeRenameMonitors {
  if (_keyMonitor) {
    [NSEvent removeMonitor:_keyMonitor];
    _keyMonitor = nil;
  }
  if (_renameClickMon) {
    [NSEvent removeMonitor:_renameClickMon];
    _renameClickMon = nil;
  }
}

- (void)controlTextDidBeginEditing:(NSNotification *)note {
  if (note.object != _name)
    return;
  NSText *ed = _name.currentEditor;
  if (![ed isKindOfClass:[NSTextView class]])
    return;
  NSColor *accent = [NSColor accentMatchingHost];
  ((NSTextView *)ed).insertionPointColor = accent;
  ((NSTextView *)ed).selectedTextAttributes = @{
    NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
    NSForegroundColorAttributeName : [NSColor labelColor],
  };
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
  if (note.object != _name)
    return;
  [self _removeRenameMonitors]; // editing over: let keys flow normally again
  // Detach the delegate now. We reuse this one field for every rename, so if
  // the delegate stayed attached the NEXT _beginRename would have it set BEFORE
  // focus - and the spurious begin/end-editing during focus would immediately
  // commit and kill typing (the "second edit does nothing" bug). _beginRename
  // re-attaches it after focus.
  _name.delegate = nil;
  // Fully drop focus before the commit below rebuilds the browser. A focused
  // view torn down during that rebuild crashes in _NSAutomaticFocusRing (the
  // Enter/Esc crash), so resign first responder now that editing has ended.
  [self.window makeFirstResponder:nil];
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    s->_name.editable = NO;
    s->_name.selectable = NO;
    s->_name.textColor = [NSColor secondaryLabelColor];
    [s.window invalidateCursorRectsForView:s];
    [[NSCursor arrowCursor] set];
    NSString *newName = [s->_name.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    [s->_owner card:s didBeginRename:NO];
    if (newName.length && ![newName isEqualToString:s->_item.name])
      [s->_owner cardRename:s toName:newName];
    else
      s->_name.stringValue = s->_item.name ?: @"";
  });
}

// Enter commits, Esc reverts - both drop focus (which ends editing and runs the
// commit in controlTextDidEndEditing). Esc doesn't reach the field editor's
// cancelOperation on its own in this panel, so handle both here.
- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)selector {
  if (control != _name)
    return NO;
  if (selector == @selector(cancelOperation:)) {
    _name.stringValue = _item.name ?: @""; // revert before the commit reads it
    [_name.window makeFirstResponder:nil];
    return YES;
  }
  if (selector == @selector(insertNewline:)) {
    [_name.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

- (void)dealloc {
  [self _removeRenameMonitors];
}
@end
