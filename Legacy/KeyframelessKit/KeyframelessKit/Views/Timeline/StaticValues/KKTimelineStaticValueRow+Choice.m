/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Choice (enum) rows presented as a dropdown: mapping the stored value to a
// choice index and back, the trigger title, the "unknown value" warning, and
// the checklist popover (open / pick / close). The pill-based choice variant is
// built inline in initWithLane; this covers the dropdown path. Split out of
// KKTimelineStaticValueRow.m; reaches row state via the @package ivars in
// KKTimelineStaticValueRow_Private.h.

#import "KKChoiceChecklistView.h"
#import "KKLocalized.h"
#import "KKPopoverKeepAlive.h"
#import "KKTimelineStaticValueRow_Private.h"
#import "KKTokens.h" // KKPaddingMD
#import "NSColor+KKColors.h"
#import <math.h>

@interface _KKStaticValueRow (ChoicePrivate)
- (NSInteger)_choiceIndexForStored:(double)stored;
- (double)_storedChoiceValue;
- (NSIndexSet *)_selectedChoiceIndexes;
- (void)_syncChoiceWarning:(BOOL)show;
@end

@implementation _KKStaticValueRow (Choice)

- (NSInteger)_choiceIndexForStored:(double)stored {
  if (!_choiceValues.count)
    return (NSInteger)llround(stored);
  for (NSInteger i = 0; i < (NSInteger)_choiceValues.count; i++)
    if (llround(_choiceValues[i].doubleValue) == llround(stored))
      return i;
  return -1;
}

// Choice index -> the value the lane stores. `choiceValues` lets a lane whose
// choices come and go hold a stable id instead of a position.
- (double)_storedForChoiceIndex:(NSInteger)index {
  if (index >= 0 && index < (NSInteger)_choiceValues.count)
    return _choiceValues[index].doubleValue;
  return (double)index;
}

- (NSInteger)_selectedChoiceIndex {
  if (!_values.count)
    return -1;
  return [self _choiceIndexForStored:_values[0].doubleValue];
}

- (NSIndexSet *)_selectedChoiceIndexes {
  uint32_t mask =
      _values.count ? (uint32_t)llround(fmax(0.0, _values[0].doubleValue)) : 0;
  NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
  for (NSInteger i = 0; i < (NSInteger)_choiceLabels.count && i < 24; i++)
    if (mask & (1u << i))
      [indexes addIndex:i];
  return indexes;
}

- (void)_syncChoiceFieldTitle {
  if (_choiceAllowsMultiple) {
    NSIndexSet *indexes = [self _selectedChoiceIndexes];
    NSMutableArray<NSString *> *selected = [NSMutableArray array];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      if (i < self->_choiceLabels.count)
        [selected addObject:self->_choiceLabels[i]];
    }];
    NSMutableArray<NSString *> *localized =
        [NSMutableArray arrayWithCapacity:selected.count];
    for (NSString *label in selected)
      [localized addObject:KKLocalizedParamName(label)];
    _choiceField.summaryOverride =
        localized.count ? [localized componentsJoinedByString:@", "]
                        : KKLocalizedParamName(@"None");
    _choiceField.selectedLabels = selected.count ? selected : nil;
    [_choiceField setNeedsDisplay:YES];
    [self _syncChoiceWarning:NO];
    return;
  }

  NSInteger sel = [self _selectedChoiceIndex];
  BOOL valid = sel >= 0 && sel < (NSInteger)_choiceLabels.count;
  // A stored value naming no current choice is NOT the same as picking "None",
  // even though both render nothing and both fall back to defaults. Ask the
  // owner what it was: Shader remembers the Sonar source a lane is bound to,
  // so "Dialogue + Music - DEMO 1" survives even where it isn't published.
  NSString *unknown =
      valid ? nil : _choiceUnknownLabels[@([self _storedChoiceValue])];
  // "None" rather than blank when nothing at all is known, so an unset lane
  // reads as unset instead of broken. Already a param name, so it localizes
  // with the choice labels and needs no new string.
  _choiceField.summaryOverride =
      unknown ?: KKLocalizedParamName(valid ? _choiceLabels[sel] : @"None");
  // `selectedLabels` is what the trigger reads as "has a selection", which
  // dims the text when it doesn't - so an unset picker greys its "None" exactly
  // like the Animated dropdown greys its placeholder. A remembered-but-missing
  // pick stays dimmed too: it names something that isn't selectable here.
  _choiceField.selectedLabels = valid ? @[ _choiceLabels[sel] ] : nil;
  [_choiceField setNeedsDisplay:YES];
  [self _syncChoiceWarning:(unknown != nil)];
}

- (double)_storedChoiceValue {
  return _values.count ? _values[0].doubleValue : 0.0;
}

/// Shows the owner's warning in the gap between the lane's name and its value
/// control - the one place on the row nothing else claims.
- (void)_syncChoiceWarning:(BOOL)show {
  if (!show || !_choiceUnknownBadge.length) {
    _choiceWarning.hidden = YES;
    return;
  }
  if (!_choiceWarning) {
    _choiceWarning = _KKMakeCaption(_choiceUnknownBadge);
    _choiceWarning.attributedStringValue =
        _KKWarningCaption(_choiceUnknownBadge, [NSColor warning]);
    [self addSubview:_choiceWarning];
    [NSLayoutConstraint activateConstraints:@[
      [_choiceWarning.trailingAnchor
          constraintEqualToAnchor:_choiceField.leadingAnchor
                         constant:-KKPaddingMD],
      [_choiceWarning.centerYAnchor
          constraintEqualToAnchor:_choiceField.centerYAnchor],
    ]];
    // Compressible so a long localization gives way to the value column rather
    // than shoving it off the row.
    [_choiceWarning
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
  }
  // Re-set rather than set once at creation: the trigger's text is what names
  // the source, and it changes as the row is reused for other values.
  _choiceWarning.toolTip = [NSString
      stringWithFormat:@"%@ - %@", _choiceField.summaryOverride ?: @"",
                       _choiceUnknownBadge];
  _choiceWarning.hidden = NO;
}

// A popover off the trigger, like the Animated dropdown.
//
// This one opens from INSIDE the Constants popover, which would normally
// dismiss the moment a click lands in another window. Registering the child as
// a keep-alive window is what makes the parent treat clicks in it as its own -
// the same mechanism the companion side panels use.
- (void)_toggleChoiceList {
  if (_choicePopover) {
    [_choicePopover performClose:nil];
    return;
  }
  if (_choiceAllowsMultiple)
    _choiceList = [[KKChoiceChecklistView alloc]
        initWithOptions:_choiceLabels
        selectedIndexes:[self _selectedChoiceIndexes]
          maxBodyHeight:kChoiceListMaxBody];
  else
    _choiceList = [[KKChoiceChecklistView alloc]
        initWithOptions:_choiceLabels
          selectedIndex:[self _selectedChoiceIndex]
          maxBodyHeight:kChoiceListMaxBody];
  __weak typeof(self) weak = self;
  if (_choiceAllowsMultiple) {
    _choiceList.onToggle = ^(NSInteger index, BOOL selected) {
      __strong typeof(weak) s = weak;
      if (!s || index < 0 || index >= 24)
        return;
      uint32_t mask =
          s->_values.count
              ? (uint32_t)llround(fmax(0.0, s->_values[0].doubleValue))
              : 0;
      if (selected)
        mask |= 1u << index;
      else
        mask &= ~(1u << index);
      [s _setValues:@[ @((double)mask) ] emit:YES];
      [s _syncChoiceFieldTitle];
    };
  } else {
    _choiceList.onSelect = ^(NSInteger index) {
      __strong typeof(weak) s = weak;
      if (!s)
        return;
      [s _setValues:@[ @([s _storedForChoiceIndex:index]) ] emit:YES];
      [s _syncChoiceFieldTitle];
      [s->_choicePopover performClose:nil]; // a pick ends the interaction
    };
  }

  // Wrapped, not set as the content view directly: the wrapper is what strips
  // the system popover's own glass + border once it has a window. Without it
  // the kit's chrome and AppKit's both draw, and the list wears two borders.
  _KKLVPopoverContentView *wrapper = [[_KKLVPopoverContentView alloc] init];
  wrapper.frame = _choiceList.bounds;
  _choiceList.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:_choiceList];
  [NSLayoutConstraint activateConstraints:@[
    [_choiceList.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
    [_choiceList.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    [_choiceList.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [_choiceList.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = wrapper;
  _choicePopover = [[NSPopover alloc] init];
  _choicePopover.contentViewController = vc;
  _choicePopover.behavior = NSPopoverBehaviorTransient;
  _choicePopover.delegate = self;
  // Before sizing: the list only knows it is the popover's whole content once
  // this is set, and -refilterAndResize is what sizes the popover to the capped
  // list (an options list longer than the old fixed minimum used to be clipped
  // with no way to reach the tail).
  _choiceList.popover = _choicePopover;
  [_choiceList refilterAndResize];
  [_choicePopover showRelativeToRect:_choiceField.bounds
                              ofView:_choiceField
                       preferredEdge:NSRectEdgeMinY];
  // Only available once shown.
  KKPopoverAddKeepAliveWindow(_choiceList.window);
}

- (void)popoverDidClose:(NSNotification *)notification {
  KKPopoverRemoveKeepAliveWindow(_choiceList.window);
  _choicePopover = nil;
  _choiceList = nil;
}

@end
