/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPresetsPopover.h"

#import "KKLocalized.h"
#import "KKPopoverHeaderView.h"
#import "KKPresetRowView.h"
#import "KKPresets.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

static const CGFloat kSaveRowHeight = 32.0;
static const CGFloat kEmptyRowHeight = 28.0;
static const CGFloat kMaxVisibleRows = 7;

// Same macOS 26 liquid-glass double-border fix the gradient/curve popovers use.
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

@interface KKPresetsContentView : NSView
@end

@implementation KKPresetsContentView

- (BOOL)isFlipped {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window)
    _clearPopoverBackground(self);
}

@end

@interface KKPresetsPopover () <NSTextFieldDelegate, NSPopoverDelegate>
@end

@implementation KKPresetsPopover {
  NSPopover *_popover;
  KKPresetsContentView *_contentView;
  KKPopoverHeaderView *_header;
  NSScrollView *_listScroll;
  KKPresetsFlippedView *_listContainer;
  NSBox *_separator;
  NSView *_saveRow;
  NSButton *_saveButton;
  NSTextField *_emptyLabel;
  KKPresetNameTextField *_filterField;
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

  [self _buildChrome];
  [self _reloadList];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = _contentView;

  _popover = [[NSPopover alloc] init];
  _popover.contentViewController = vc;
  // ApplicationDefined during a guide so the overlay/host clicks don't dismiss
  // it; Transient otherwise.
  _popover.behavior = _guideMode ? NSPopoverBehaviorApplicationDefined
                                 : NSPopoverBehaviorTransient;
  _popover.delegate = self;
  _popover.contentSize = _contentView.frame.size;
  [_popover showRelativeToRect:rect ofView:view preferredEdge:NSRectEdgeMinY];
  // A guide drives the popover with narrated steps; the filter field auto-
  // focuses on open, so clear it (next tick, after the popover sets its initial
  // responder) to keep keystrokes out of it during the walkthrough.
  if (_guideMode) {
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weak.popoverWindow makeFirstResponder:nil];
    });
  }
  if (self.onDidShow)
    self.onDidShow();
}

// Persistent chrome built once: a scrollable list region, a separator, and the
// combined filter/name field + save button. `_reloadList` fills and sizes it in
// place so typing-to-filter keeps the field focused (no close/reopen).
- (void)_buildChrome {
  _contentView = [[KKPresetsContentView alloc]
      initWithFrame:NSMakeRect(0, 0, KKPresetPopoverWidth, kSaveRowHeight)];

  // Title row matches the motion-blur / constants popovers (dimmed icon+title).
  _header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Presets",
                          @"Section title: saved animation presets.")
         symbolName:@"bookmark"];
  _header.translatesAutoresizingMaskIntoConstraints = YES;
  [_contentView addSubview:_header];

  _listContainer = [[KKPresetsFlippedView alloc]
      initWithFrame:NSMakeRect(0, 0, KKPresetPopoverWidth, KKPresetRowHeight)];
  _listContainer.autoresizesSubviews = NO;

  _listScroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(0, 0, KKPresetPopoverWidth, KKPresetRowHeight)];
  _listScroll.documentView = _listContainer;
  _listScroll.hasVerticalScroller = YES;
  _listScroll.autohidesScrollers = YES;
  _listScroll.drawsBackground = NO;
  _listScroll.autoresizingMask = NSViewWidthSizable;
  [_contentView addSubview:_listScroll];

  _emptyLabel = [NSTextField labelWithString:@""];
  _emptyLabel.font = [NSFont systemFontOfSize:11.0];
  _emptyLabel.textColor = [NSColor.inspectorLabel colorWithAlphaComponent:0.4];
  _emptyLabel.alignment = NSTextAlignmentCenter;
  _emptyLabel.autoresizingMask = NSViewWidthSizable;
  _emptyLabel.hidden = YES;
  [_contentView addSubview:_emptyLabel];

  _separator = [[NSBox alloc] initWithFrame:NSZeroRect];
  _separator.boxType = NSBoxSeparator;
  [_contentView addSubview:_separator];

  _saveRow = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, KKPresetPopoverWidth, kSaveRowHeight)];
  _saveRow.autoresizingMask = NSViewWidthSizable;

  _filterField = [[KKPresetNameTextField alloc] initWithFrame:NSZeroRect];
  _filterField.placeholderString =
      KKLoc(@"Filter or name",
            @"Placeholder: type to filter the preset list, or to name a new "
            @"preset.");
  _filterField.font = [NSFont systemFontOfSize:11.0];
  _filterField.textColor = [NSColor inspectorLabel];
  _filterField.bezeled = YES;
  _filterField.bezelStyle = NSTextFieldRoundedBezel;
  _filterField.focusRingType = NSFocusRingTypeNone;
  _filterField.translatesAutoresizingMaskIntoConstraints = NO;
  _filterField.delegate = self;
  [_saveRow addSubview:_filterField];

  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:11.0
                          weight:NSFontWeightMedium];
  NSImage *plusImg = [[NSImage
      imageWithSystemSymbolName:@"plus"
       accessibilityDescription:KKLoc(@"Save preset",
                                      @"Accessibility: save the current "
                                      @"animation as a preset.")]
      imageWithSymbolConfiguration:cfg];
  NSButton *saveBtn = [NSButton buttonWithImage:plusImg
                                         target:self
                                         action:@selector(_saveTapped:)];
  saveBtn.bordered = NO;
  saveBtn.contentTintColor = [NSColor inspectorLabel];
  saveBtn.toolTip =
      KKLoc(@"Save preset", @"Accessibility: save the current animation as a "
                            @"preset.");
  saveBtn.translatesAutoresizingMaskIntoConstraints = NO;
  _saveButton = saveBtn;
  [_saveRow addSubview:saveBtn];

  [NSLayoutConstraint activateConstraints:@[
    [_filterField.leadingAnchor constraintEqualToAnchor:_saveRow.leadingAnchor
                                               constant:KKPaddingLG],
    [_filterField.centerYAnchor constraintEqualToAnchor:_saveRow.centerYAnchor],
    [_filterField.trailingAnchor constraintEqualToAnchor:saveBtn.leadingAnchor
                                                constant:-KKSpacingSM],
    [saveBtn.trailingAnchor constraintEqualToAnchor:_saveRow.trailingAnchor
                                           constant:-KKPaddingLG],
    [saveBtn.centerYAnchor constraintEqualToAnchor:_saveRow.centerYAnchor],
    [saveBtn.widthAnchor constraintEqualToConstant:20.0],
    [saveBtn.heightAnchor constraintEqualToConstant:20.0],
  ]];
  [_contentView addSubview:_saveRow];
}

- (NSString *)_filterText {
  return [_filterField.stringValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
}

- (NSArray<KKPreset *> *)_filteredPresets {
  NSArray<KKPreset *> *all =
      [[KKPresets shared] presetsForPluginKey:(_pluginKey ?: @"")];
  NSString *q = [self _filterText];
  if (q.length == 0)
    return all;
  NSMutableArray<KKPreset *> *out = [NSMutableArray new];
  for (KKPreset *p in all)
    if ([p.displayName rangeOfString:q options:NSCaseInsensitiveSearch]
            .location != NSNotFound)
      [out addObject:p];
  return out;
}

// Rebuild the list rows in place and resize the popover - never close/reopen,
// so the filter field keeps focus while typing.
- (void)_reloadList {
  NSArray<KKPreset *> *presets = [self _filteredPresets];
  for (NSView *v in [_listContainer.subviews copy])
    [v removeFromSuperview];

  __weak typeof(self) weakSelf = self;
  CGFloat rowY = 0;
  for (KKPreset *preset in presets) {
    KKPresetRowView *row = [[KKPresetRowView alloc] initWithPreset:preset];
    row.frame = NSMakeRect(0, rowY, KKPresetPopoverWidth, KKPresetRowHeight);
    row.autoresizingMask = NSViewWidthSizable;
    row.onApply = ^(KKPreset *p, BOOL atPlayhead) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      // Defer the close: closing an NSPopover from inside its own click handler
      // in an XPC view service crashes via ViewBridge re-entrancy.
      if (strongSelf.onApplyPreset && p.timelineJSON.length)
        strongSelf.onApplyPreset(p.timelineJSON, atPlayhead);
      if (strongSelf.onDidApplyPreset)
        strongSelf.onDidApplyPreset();
      // A guide keeps the popover open to chain apply -> insert -> save; it
      // closes it itself on completion.
      if (strongSelf.guideMode)
        return;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (strongSelf->_popover)
          [strongSelf->_popover close];
      });
    };
    row.onDelete = ^(NSString *identifier) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      [[KKPresets shared] removePresetWithIdentifier:identifier];
      [strongSelf _reloadList];
    };
    row.onOverwrite = ^(NSString *identifier) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      NSString *json = strongSelf.currentTimelineJSON
                           ? strongSelf.currentTimelineJSON()
                           : nil;
      if (!json.length)
        return;
      [[KKPresets shared] updatePresetWithIdentifier:identifier
                                        timelineJSON:json];
      [strongSelf _reloadList];
    };
    row.onRename = ^(NSString *identifier, NSString *newName) {
      [[KKPresets shared] renamePresetWithIdentifier:identifier toName:newName];
    };
    [_listContainer addSubview:row];
    rowY += KKPresetRowHeight;
  }

  CGFloat listHeight = presets.count * KKPresetRowHeight;
  CGFloat clipped = fmin(listHeight, kMaxVisibleRows * KKPresetRowHeight);
  BOOL hasItems = presets.count > 0;
  CGFloat listRegion = hasItems ? clipped : kEmptyRowHeight;

  CGFloat headerH = [KKPopoverHeaderView height];
  _header.frame = NSMakeRect(KKPaddingMD, KKPaddingMD,
                             KKPresetPopoverWidth - KKPaddingMD * 2, headerH);
  CGFloat listTop = KKPaddingMD + headerH + KKSpacingSM;

  _listContainer.frame =
      NSMakeRect(0, 0, KKPresetPopoverWidth, fmax(listHeight, 1.0));
  _listScroll.frame = NSMakeRect(0, listTop, KKPresetPopoverWidth, listRegion);
  _listScroll.hidden = !hasItems;

  _emptyLabel.hidden = hasItems;
  if (!hasItems) {
    _emptyLabel.stringValue =
        [self _filterText].length > 0
            ? KKLoc(@"No matches",
                    @"Empty state when a preset filter matches nothing.")
            : KKLoc(@"No presets saved", @"Empty state for the preset list.");
    _emptyLabel.frame = NSMakeRect(0, listTop + (kEmptyRowHeight - 16.0) / 2.0,
                                   KKPresetPopoverWidth, 16.0);
  }

  CGFloat y = listTop + listRegion;
  _separator.frame =
      NSMakeRect(KKPaddingLG, y, KKPresetPopoverWidth - KKPaddingLG * 2, 1);
  y += KKSpacingSM;
  _saveRow.frame = NSMakeRect(0, y, KKPresetPopoverWidth, kSaveRowHeight);
  y += kSaveRowHeight;

  // Before the popover exists, size the content view so showRelativeToRect can
  // read it. Once shown, the popover OWNS the content view's frame - setting it
  // ourselves fights the popover and shifts the content on every keystroke;
  // just drive the size through contentSize.
  if (_popover.isShown)
    _popover.contentSize = NSMakeSize(KKPresetPopoverWidth, y);
  else
    _contentView.frame = NSMakeRect(0, 0, KKPresetPopoverWidth, y);
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (control == _filterField && commandSelector == @selector(insertNewline:)) {
    [self _saveTapped:nil];
    return YES;
  }
  return NO;
}

- (void)controlTextDidChange:(NSNotification *)note {
  if (note.object == _filterField)
    [self _reloadList];
}

- (void)_saveTapped:(id)sender {
  NSString *name = [self _filterText];
  if (name.length == 0)
    return;
  NSString *json = _currentTimelineJSON ? _currentTimelineJSON() : nil;
  if (!json.length)
    return;
  KKPreset *saved = [[KKPresets shared]
      addPresetWithName:name
              pluginKey:(_pluginKey ?: @"")timelineJSON:json];
  _filterField.stringValue = @"";
  [self _reloadList];
  if (self.onDidSavePreset && saved.identifier)
    self.onDidSavePreset(saved.identifier);
}

- (void)popoverDidClose:(NSNotification *)notification {
  _popover = nil;
}

#pragma mark - Guide support

- (NSWindow *)popoverWindow {
  return _contentView.window;
}

- (KKPresetRowView *)_firstRow {
  for (NSView *v in _listContainer.subviews)
    if ([v isKindOfClass:[KKPresetRowView class]])
      return (KKPresetRowView *)v;
  return nil;
}

- (NSRect)guidePopoverScreenRect {
  return KKPresetScreenRectForView(_contentView);
}

- (NSRect)guideFirstRowScreenRect {
  return KKPresetScreenRectForView([self _firstRow]);
}

- (NSRect)guideFirstRowInsertButtonScreenRect {
  return [[self _firstRow] insertButtonScreenRect];
}

- (NSRect)guideSaveAreaScreenRect {
  NSRect f = KKPresetScreenRectForView(_filterField);
  NSRect b = KKPresetScreenRectForView(_saveButton);
  if (NSIsEmptyRect(f))
    return b;
  if (NSIsEmptyRect(b))
    return f;
  return NSUnionRect(f, b);
}

- (void)guidePrefillName:(NSString *)name {
  _filterField.stringValue = name ?: @"";
  [self _reloadList];
}

- (void)closeForGuide {
  [_popover close];
}

@end
