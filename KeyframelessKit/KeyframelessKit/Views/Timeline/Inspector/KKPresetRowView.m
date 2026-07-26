/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPresetRowView.h"
#import "KKViewHelpers.h" // KKTrackingAreaMatches

#import "KKHelpViewSubviews.h" // _KKCapsuleView (app-wide InfoBadge look)
#import "KKLocalized.h"
#import "KKPresets.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

const CGFloat KKPresetPopoverWidth = 280.0;
const CGFloat KKPresetRowHeight = 28.0;

NSRect KKPresetScreenRectForView(NSView *v) {
  NSWindow *w = v.window;
  if (!v || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[v convertRect:v.bounds toView:nil]];
}

@implementation KKPresetsFlippedView
- (BOOL)isFlipped {
  return YES;
}
@end

@implementation KKPresetNameTextField

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSText *editor = self.currentEditor;
  // In an FxPlug ViewBridge popover there's no Edit menu, so the standard
  // Cmd-A / C / V / X key equivalents never route to the field editor. Dispatch
  // them to it explicitly while we're being edited.
  if (editor &&
      (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) ==
          NSEventModifierFlagCommand) {
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    if ([key isEqualToString:@"a"]) {
      [editor selectAll:nil];
      return YES;
    }
    if ([key isEqualToString:@"c"]) {
      [editor copy:nil];
      return YES;
    }
    if ([key isEqualToString:@"v"]) {
      [editor paste:nil];
      return YES;
    }
    if ([key isEqualToString:@"x"]) {
      [editor cut:nil];
      return YES;
    }
  }
  if (editor) {
    [editor keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    NSTextView *editor = (NSTextView *)self.currentEditor;
    NSColor *accent = [NSColor accentMatchingHost];
    editor.insertionPointColor = accent;
    editor.selectedTextAttributes = @{
      NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
      NSForegroundColorAttributeName : [NSColor labelColor],
    };
  }
  return ok;
}

@end

@implementation KKPresetRowView {
  NSTextField *_nameField;
  NSButton *_applyAtButton;
  NSButton *_renameButton;
  NSButton *_overwriteButton;
  NSButton *_deleteButton;
}

- (instancetype)initWithPreset:(KKPreset *)preset {
  self = [super
      initWithFrame:NSMakeRect(0, 0, KKPresetPopoverWidth, KKPresetRowHeight)];
  if (!self)
    return nil;
  _preset = preset;
  self.wantsLayer = YES; // hover highlight
  self.toolTip = KKLoc(@"Apply preset (replace)",
                       @"Tooltip: clicking a preset row replaces the current "
                       @"animation.");

  _nameField = [[KKPresetNameTextField alloc] initWithFrame:NSZeroRect];
  _nameField.stringValue = preset.displayName;
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

  // Every row carries an "apply at playhead" button; clicking the row body
  // applies as an override.
  _applyAtButton = [self
        _iconButton:@"text.insert"
      accessibility:KKLoc(@"Apply preset at playhead",
                          @"Accessibility: insert the preset's animation at "
                          @"the current playhead, keeping existing keyposes.")
             config:cfg
             action:@selector(_applyAtTapped:)];
  // Accent-tinted (host-matching) so the primary "insert here" action stands
  // apart from the muted rename/overwrite/delete glyphs.
  _applyAtButton.contentTintColor = [NSColor accentMatchingHost];
  [self addSubview:_applyAtButton];

  [NSLayoutConstraint activateConstraints:@[
    [_nameField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:KKPaddingLG],
    [_nameField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_applyAtButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
  ]];

  // Trailing cluster laid out right-to-left; _applyAtButton sits leftmost of
  // it, and the name field stops before whatever is leftmost.
  if (preset.builtin) {
    NSView *badge = [self _buildDefaultBadge];
    [self addSubview:badge];
    [NSLayoutConstraint activateConstraints:@[
      [badge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-KKPaddingLG],
      [badge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_applyAtButton.trailingAnchor constraintEqualToAnchor:badge.leadingAnchor
                                                    constant:-KKSpacingMD],
    ]];
  } else {
    _renameButton =
        [self _iconButton:@"pencil"
            accessibility:KKLoc(@"Rename preset",
                                @"Accessibility: rename the saved preset.")
                   config:cfg
                   action:@selector(_renameTapped:)];
    _overwriteButton = [self
          _iconButton:@"square.and.arrow.down"
        accessibility:KKLoc(@"Overwrite preset with current animation",
                            @"Accessibility: replace a saved preset with the "
                            @"current animation.")
               config:cfg
               action:@selector(_overwriteTapped:)];
    _deleteButton =
        [self _iconButton:@"trash"
            accessibility:KKLoc(@"Delete preset",
                                @"Accessibility: delete the saved preset.")
                   config:cfg
                   action:@selector(_deleteTapped:)];
    [self addSubview:_renameButton];
    [self addSubview:_overwriteButton];
    [self addSubview:_deleteButton];

    [NSLayoutConstraint activateConstraints:@[
      [_deleteButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                   constant:-KKPaddingLG],
      [_deleteButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_overwriteButton.trailingAnchor
          constraintEqualToAnchor:_deleteButton.leadingAnchor
                         constant:-KKSpacingMD],
      [_overwriteButton.centerYAnchor
          constraintEqualToAnchor:self.centerYAnchor],
      [_renameButton.trailingAnchor
          constraintEqualToAnchor:_overwriteButton.leadingAnchor
                         constant:-KKSpacingMD],
      [_renameButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_applyAtButton.trailingAnchor
          constraintEqualToAnchor:_renameButton.leadingAnchor
                         constant:-KKSpacingMD],
    ]];
  }
  [_nameField.trailingAnchor
      constraintLessThanOrEqualToAnchor:_applyAtButton.leadingAnchor
                               constant:-KKSpacingSM]
      .active = YES;
  return self;
}

- (NSButton *)_iconButton:(NSString *)symbol
            accessibility:(NSString *)accessibility
                   config:(NSImageSymbolConfiguration *)cfg
                   action:(SEL)action {
  NSImage *img = [[NSImage imageWithSystemSymbolName:symbol
                            accessibilityDescription:accessibility]
      imageWithSymbolConfiguration:cfg];
  NSButton *button = [NSButton buttonWithImage:img target:self action:action];
  button.bordered = NO;
  button.contentTintColor =
      [NSColor.inspectorLabel colorWithAlphaComponent:0.4];
  button.toolTip = accessibility;
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [button.widthAnchor constraintEqualToConstant:16.0],
    [button.heightAnchor constraintEqualToConstant:16.0],
  ]];
  return button;
}

// Matches the docs window / app-wide InfoBadge: self-rounding capsule,
// inspectorLabel fill at 15%, label at 60% in 9pt medium.
- (NSView *)_buildDefaultBadge {
  NSColor *badgeColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.6];
  _KKCapsuleView *badge = [[_KKCapsuleView alloc] initWithFrame:NSZeroRect];
  badge.translatesAutoresizingMaskIntoConstraints = NO;
  badge.wantsLayer = YES;
  badge.layer.backgroundColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.15].CGColor;
  [badge setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [badge setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                  forOrientation:
                                      NSLayoutConstraintOrientationHorizontal];

  NSTextField *label = [NSTextField
      labelWithString:KKLoc(@"Default",
                            @"Badge on a built-in (shipped) preset.")];
  label.font = [NSFont systemFontOfSize:9.0 weight:NSFontWeightMedium];
  label.textColor = badgeColor;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [badge addSubview:label];
  [NSLayoutConstraint activateConstraints:@[
    [label.leadingAnchor constraintEqualToAnchor:badge.leadingAnchor
                                        constant:KKPaddingSM + 1.0],
    [label.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor
                                         constant:-(KKPaddingSM + 1.0)],
    [label.topAnchor constraintEqualToAnchor:badge.topAnchor
                                    constant:KKPaddingXS],
    [label.bottomAnchor constraintEqualToAnchor:badge.bottomAnchor
                                       constant:-KKPaddingXS],
  ]];
  return badge;
}

- (void)_renameTapped:(id)sender {
  _nameField.editable = YES;
  _nameField.selectable = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self->_nameField];
    self->_nameField.currentEditor.selectedRange =
        NSMakeRange(0, self->_nameField.stringValue.length);
  });
}

- (void)_applyAtTapped:(id)sender {
  if (_onApply)
    _onApply(_preset, YES);
}

- (void)_overwriteTapped:(id)sender {
  if (_onOverwrite)
    _onOverwrite(_preset.identifier);
}

- (void)_deleteTapped:(id)sender {
  if (_onDelete)
    _onDelete(_preset.identifier);
}

- (void)mouseDown:(NSEvent *)event {
  // While inline-renaming, a click anywhere else just commits the edit.
  if (_nameField.editable) {
    [self.window makeFirstResponder:nil];
    return;
  }
  // Clicking the row body applies as an override (the playhead button merges).
  if (_onApply)
    _onApply(_preset, NO);
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  // InVisibleRect, so an existing one needs no rebuild at all.
  if (self.trackingAreas.count == 1)
    return;
  for (NSTrackingArea *ta in [self.trackingAreas copy])
    [self removeTrackingArea:ta];
  NSTrackingArea *ta = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:(NSTrackingMouseEnteredAndExited | NSTrackingCursorUpdate |
                    NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:ta];
}

- (void)mouseEntered:(NSEvent *)event {
  self.layer.backgroundColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.08].CGColor;
}

- (void)mouseExited:(NSEvent *)event {
  self.layer.backgroundColor = NSColor.clearColor.CGColor;
}

- (void)cursorUpdate:(NSEvent *)event {
  [[NSCursor pointingHandCursor] set];
}

- (NSRect)insertButtonScreenRect {
  return KKPresetScreenRectForView(_applyAtButton);
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
  _nameField.editable = NO;
  _nameField.selectable = NO;
  NSString *newName = [_nameField.stringValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (newName.length > 0 && ![newName isEqualToString:_preset.displayName] &&
      _onRename)
    _onRename(_preset.identifier, newName);
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (commandSelector == @selector(insertNewline:)) {
    [self.window makeFirstResponder:nil];
    return YES;
  }
  if (commandSelector == @selector(cancelOperation:)) {
    _nameField.stringValue = _preset.displayName;
    _nameField.editable = NO;
    _nameField.selectable = NO;
    [self.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

@end
