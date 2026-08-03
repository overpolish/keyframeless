/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The optional save strip: a name field, an optional category picker (its
// dropdown + checklist popover), and the Save button, plus the name-field
// delegate. Split out of KKCodeEditorView.m; reaches editor state via the
// @package ivars in KKCodeEditorView_Private.h. `setSavable:` stays in the main
// .m with the other config setters (it toggles the synthesized `savable`).

#import "KKChoiceChecklistView.h"
#import "KKCodeEditorView_Private.h"
#import "KKLocalized.h"
#import "KKPopoverKeepAlive.h"          // keep-alive window registration
#import "KKTimelineLanesView_Private.h" // _KKDropdownTrigger
#import "KKTokens.h"
#import "NSColor+KKColors.h"

// Wide enough for the longest category a host is likely to offer without the
// name field losing its own room.
static const CGFloat kSaveCategoryW = 96.0;
// ~6 rows before the list scrolls, matching the other capped checklists.
static const CGFloat kSaveCategoryListMaxBody = 168.0;

@interface KKCodeEditorView (SaveBarPrivate)
- (void)_syncSaveCategoryTitle;
@end

@implementation KKCodeEditorView (SaveBar)

- (NSString *)saveNamePlaceholder {
  return _saveNameField.placeholderString;
}

- (void)setSaveNamePlaceholder:(NSString *)placeholder {
  _saveNameField.placeholderString =
      placeholder.length
          ? placeholder
          : KKLoc(@"Name",
                  @"Code editor save-bar name field placeholder (generic).");
}

- (NSString *)saveName {
  return _saveNameField.stringValue ?: @"";
}

- (void)setSaveName:(NSString *)name {
  NSString *n = name ?: @"";
  if ([_saveNameField.stringValue isEqualToString:n])
    return; // don't disturb an in-progress edit with an identical re-apply
  // Nor a live one with a different value: this is now re-applied on every
  // timeline apply so a template change updates the name, and an apply landing
  // mid-type would take the caret and the half-typed name with it. The commit
  // on blur is what puts the typed name back on the lane.
  if (_saveNameField.currentEditor)
    return;
  _saveNameField.stringValue = n;
  _saveButton.enabled =
      [n stringByTrimmingCharactersInSet:NSCharacterSet
                                             .whitespaceAndNewlineCharacterSet]
          .length > 0;
}

- (NSArray<NSString *> *)saveCategoryLabels {
  return _saveCategoryLabels;
}

- (void)setSaveCategoryLabels:(NSArray<NSString *> *)labels {
  _saveCategoryLabels = [labels copy];
  BOOL on = _saveCategoryLabels.count > 0;
  _saveCategoryField.hidden = !on;
  _saveCategoryWidth.constant = on ? kSaveCategoryW : 0.0;
  _saveCategoryGap.constant = on ? -6.0 : 0.0;
  if (_saveCategoryIndex >= (NSInteger)_saveCategoryLabels.count)
    _saveCategoryIndex = 0; // a shorter list can't leave the pick dangling
  [self _syncSaveCategoryTitle];
}

- (NSInteger)saveCategoryIndex {
  return (_saveCategoryIndex >= 0 &&
          _saveCategoryIndex < (NSInteger)_saveCategoryLabels.count)
             ? _saveCategoryIndex
             : 0;
}

- (void)setSaveCategoryIndex:(NSInteger)index {
  _saveCategoryIndex = index;
  [self _syncSaveCategoryTitle];
}

- (void)_syncSaveCategoryTitle {
  NSInteger i = self.saveCategoryIndex;
  NSString *title =
      i < (NSInteger)_saveCategoryLabels.count ? _saveCategoryLabels[i] : nil;
  _saveCategoryField.summaryOverride = title;
  // What the trigger reads as "has a selection" - without it the title draws
  // dimmed, like an unset picker.
  _saveCategoryField.selectedLabels = title ? @[ title ] : nil;
  _saveCategoryField.rightAligned = NO;
  [_saveCategoryField setNeedsDisplay:YES];
}

// The picker's popover, built exactly like a `#choice dropdown` lane's: the
// wrapper strips AppKit's own glass so the kit's chrome isn't double-drawn, and
// the keep-alive registration stops the nonactivating host window from
// dismissing it the moment the click lands in the child window.
- (void)_toggleSaveCategoryList {
  if (_saveCategoryPopover) {
    [_saveCategoryPopover performClose:nil];
    return;
  }
  if (!_saveCategoryLabels.count)
    return;
  _saveCategoryList =
      [[KKChoiceChecklistView alloc] initWithOptions:_saveCategoryLabels
                                       selectedIndex:self.saveCategoryIndex
                                       maxBodyHeight:kSaveCategoryListMaxBody];
  __weak typeof(self) weak = self;
  _saveCategoryList.onSelect = ^(NSInteger index) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s.saveCategoryIndex = index;
    [s->_saveCategoryPopover performClose:nil]; // a pick ends the interaction
  };

  _KKLVPopoverContentView *wrapper = [[_KKLVPopoverContentView alloc] init];
  wrapper.frame = _saveCategoryList.bounds;
  _saveCategoryList.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:_saveCategoryList];
  [NSLayoutConstraint activateConstraints:@[
    [_saveCategoryList.leadingAnchor
        constraintEqualToAnchor:wrapper.leadingAnchor],
    [_saveCategoryList.trailingAnchor
        constraintEqualToAnchor:wrapper.trailingAnchor],
    [_saveCategoryList.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [_saveCategoryList.bottomAnchor
        constraintEqualToAnchor:wrapper.bottomAnchor],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = wrapper;
  _saveCategoryPopover = [[NSPopover alloc] init];
  _saveCategoryPopover.contentViewController = vc;
  _saveCategoryPopover.behavior = NSPopoverBehaviorTransient;
  _saveCategoryPopover.delegate = self;
  // Wire the popover BEFORE sizing: the list only knows it is the popover's
  // whole content (rather than a section of a bigger one) once this is set, and
  // -refilterAndResize is what sizes the popover to the capped list. Skipping
  // it leaves the popover at the wrapper's init frame, which clips every row
  // past the first few until a search edit happens to re-run the resize.
  _saveCategoryList.popover = _saveCategoryPopover;
  [_saveCategoryList refilterAndResize];
  [_saveCategoryPopover showRelativeToRect:_saveCategoryField.bounds
                                    ofView:_saveCategoryField
                             preferredEdge:NSRectEdgeMinY];
  KKPopoverAddKeepAliveWindow(_saveCategoryList.window); // only once shown
}

- (void)popoverDidClose:(NSNotification *)notification {
  KKPopoverRemoveKeepAliveWindow(_saveCategoryList.window);
  _saveCategoryPopover = nil;
  _saveCategoryList = nil;
}

- (void)controlTextDidChange:(NSNotification *)note {
  if (note.object == _saveNameField)
    _saveButton.enabled =
        [_saveNameField.stringValue
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
            .length > 0;
}

// Commit the name on blur. Enter routes here too, via the doCommandBySelector
// below dropping first responder.
- (void)controlTextDidEndEditing:(NSNotification *)note {
  if (note.object != _saveNameField || !self.onSaveNameChange)
    return;
  self.onSaveNameChange([_saveNameField.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet]);
}

// Esc / Enter drop focus (blur), matching the code editor + value fields.
- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)selector {
  if (control != _saveNameField)
    return NO;
  if (selector == @selector(insertNewline:) ||
      selector == @selector(cancelOperation:)) {
    [_saveNameField.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

- (void)_saveClicked:(id)sender {
  NSString *name = [_saveNameField.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (!name.length)
    return;
  // Saving commits the name too. Without this, typing a name and hitting Save
  // straight away (no blur) would save the entry under it while the instance
  // stayed unnamed.
  if (self.onSaveNameChange)
    self.onSaveNameChange(name);
  NSMutableDictionary *info = [@{
    KKCodeEditorSaveNameKey : name,
    KKCodeEditorSaveSectionsKey : [self sections]
  } mutableCopy];
  // Absent, not 0, when the host offers no categories: 0 is a real pick, so a
  // host that never showed a picker must be able to tell the difference.
  if (_saveCategoryLabels.count)
    info[KKCodeEditorSaveCategoryIndexKey] = @(self.saveCategoryIndex);
  [[NSNotificationCenter defaultCenter]
      postNotificationName:KKCodeEditorSaveRequestedNotification
                    object:self
                  userInfo:info];
}

@end
