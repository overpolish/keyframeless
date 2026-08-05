/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The row's leading toggle buttons: the smoothing (curve) toggle, the aspect-
// link toggle, the palette-lock toggle for a lockable colour swatch, and the
// palette generator bar's mode buttons. Each builds its button, tints to the
// current state, and reports taps through the row's on* callbacks. Split out of
// KKTimelineStaticValueRow.m; reaches row state via the @package ivars in
// KKTimelineStaticValueRow_Private.h.

#import "KKLocalized.h"
#import "KKTimelineStaticValueRow_Private.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

@interface _KKStaticValueRow (TogglesPrivate)
- (void)applySmooth:(BOOL)on;
- (void)applyLink:(BOOL)on;
- (void)applyPaletteLock:(BOOL)locked;
@end

@implementation _KKStaticValueRow (Toggles)

- (NSButton *)_makeSmoothToggle {
  NSImage *img = [NSImage
      imageWithSystemSymbolName:@"point.topleft.down.to.point.bottomright."
                                @"curvepath"
       accessibilityDescription:nil];
  if (!img)
    img = [NSImage imageWithSystemSymbolName:@"scribble"
                    accessibilityDescription:nil];
  NSButton *b = [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                                   target:self
                                   action:@selector(_smoothTapped:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.toolTip = KKLoc(@"Smooth path through this keypose",
                    @"Tooltip: per-keypose curve toggle on the Position row.");
  [NSLayoutConstraint activateConstraints:@[
    [b.widthAnchor constraintEqualToConstant:15.0],
    [b.heightAnchor constraintEqualToConstant:15.0],
  ]];
  return b;
}

- (void)_updateSmoothTint {
  _smoothBtn.contentTintColor =
      _smoothOn ? [NSColor accentMatchingHost]
                : [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
}

- (void)_smoothTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  _smoothOn = !_smoothOn;
  [self _updateSmoothTint];
  if (self.onSmoothToggled)
    self.onSmoothToggled(_smoothOn);
}

- (void)applySmooth:(BOOL)on {
  _smoothOn = on;
  [self _updateSmoothTint];
}

// Link glyph that aspect-locks the two components: editing one scales the other
// by the same factor, preserving their current ratio. Global per-lane toggle.
// Lit/accent = linked, dim = unlinked.
- (NSButton *)_makeLinkToggle {
  NSImage *img = [NSImage imageWithSystemSymbolName:@"link"
                           accessibilityDescription:nil];
  NSButton *b = [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                                   target:self
                                   action:@selector(_linkTapped:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.toolTip = KKLoc(@"Link X and Y (lock aspect ratio)",
                    @"Tooltip: aspect-link toggle on the Scale row.");
  [NSLayoutConstraint activateConstraints:@[
    [b.widthAnchor constraintEqualToConstant:15.0],
    [b.heightAnchor constraintEqualToConstant:15.0],
  ]];
  return b;
}

- (void)_updateLinkTint {
  _linkBtn.contentTintColor =
      _linkOn ? [NSColor accentMatchingHost]
              : [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
}

- (void)_linkTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  _linkOn = !_linkOn;
  [self _updateLinkTint];
  if (self.onLinkToggled)
    self.onLinkToggled(_linkOn);
}

- (void)applyLink:(BOOL)on {
  _linkOn = on;
  [self _updateLinkTint];
}

// Padlock toggle beside a lockable colour swatch. Closed/accent = locked (a
// palette reroll skips this colour), open/dim = unlocked. Borderless glyph
// styled like the row's other gutter toggles.
- (NSButton *)_makePaletteLockToggle {
  NSButton *b = [NSButton buttonWithImage:[[NSImage alloc] init]
                                   target:self
                                   action:@selector(_paletteLockTapped:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.toolTip =
      KKLoc(@"Lock this colour (kept when the palette regenerates)",
            @"Tooltip: per-colour lock toggle for the palette generator.");
  [NSLayoutConstraint activateConstraints:@[
    [b.widthAnchor constraintEqualToConstant:15.0],
    [b.heightAnchor constraintEqualToConstant:15.0],
  ]];
  return b;
}

- (void)_updatePaletteLockAppearance {
  NSImage *img = [NSImage
      imageWithSystemSymbolName:(_paletteLocked ? @"lock.fill" : @"lock.open")
       accessibilityDescription:nil];
  if (img)
    _lockBtn.image = img;
  _lockBtn.contentTintColor =
      _paletteLocked ? [NSColor accentMatchingHost]
                     : [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
}

- (void)_paletteLockTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  _paletteLocked = !_paletteLocked;
  [self _updatePaletteLockAppearance];
  if (self.onPaletteLockToggled)
    self.onPaletteLockToggled(_paletteLocked);
}

- (void)applyPaletteLock:(BOOL)locked {
  _paletteLocked = locked;
  [self _updatePaletteLockAppearance];
}

// One momentary palette-bar button (glyph, with a text fallback if the SF
// symbol is unavailable).
- (NSButton *)_makePaletteButtonSymbol:(NSString *)symbol
                                  name:(NSString *)englishName
                                   tag:(NSInteger)tag
                                action:(SEL)action {
  NSString *loc = KKLocalizedParamName(englishName);
  NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                           accessibilityDescription:loc];
  NSButton *b = img ? [NSButton buttonWithImage:img target:self action:action]
                    : [NSButton buttonWithTitle:loc target:self action:action];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bezelStyle = NSBezelStyleRoundRect;
  b.controlSize = NSControlSizeSmall;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.tag = tag;
  b.toolTip = loc;
  [b.heightAnchor constraintEqualToConstant:18.0].active = YES;
  return b;
}

// Tag = mode index; tapping rerolls in that mode.
- (NSButton *)_makePaletteModeButton:(NSInteger)mode
                              symbol:(NSString *)symbol
                                name:(NSString *)englishName {
  return [self _makePaletteButtonSymbol:symbol
                                   name:englishName
                                    tag:mode
                                 action:@selector(_paletteModeTapped:)];
}

- (void)_paletteModeTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  if (self.onPaletteGenerate)
    self.onPaletteGenerate([(NSButton *)sender tag]);
}

- (void)_paletteRefineTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  if (self.onPaletteRefine)
    self.onPaletteRefine();
}

@end
