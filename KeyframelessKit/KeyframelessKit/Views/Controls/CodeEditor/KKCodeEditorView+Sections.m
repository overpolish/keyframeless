/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Tabbed code sections: parallel name/code arrays, the tab strip (build / add /
// close / select), and the external-sections apply. A single default section
// behaves like the plain editor with the strip collapsed. Split out of
// KKCodeEditorView.m; reaches editor state via the @package ivars in
// KKCodeEditorView_Private.h.

#import "KKCodeEditorView_Private.h"
#import "KKCodeTabInterchange.h" // `// #tab` multi-tab paste
#import "KKGLSLSyntax.h"         // strip colours
#import "KKLocalized.h"          // KKLoc
#import "KKTokens.h"             // sizing / weights
#import "NSColor+KKColors.h"

@interface KKCodeEditorView (SectionsPrivate)
- (void)_selectTab:(NSInteger)i;
- (NSButton *)_stripButton:(NSString *)title
                    action:(SEL)action
                       tag:(NSInteger)tag
                     color:(NSColor *)color
                      size:(CGFloat)size
                    weight:(NSFontWeight)weight;
- (void)_applySchemaButtonTitle;
@end

static NSString *KKSchemaPlainTitle(void) {
  return KKLoc(@"Copy Schema", @"Code editor: copy the template language "
                               @"reference to the clipboard.");
}

static NSString *KKSchemaOptionTitle(void) {
  return KKLoc(@"Copy Schema + Code",
               @"Code editor: Copy Schema button title while Option is held - "
               @"the copy will also include the user's template code.");
}

@implementation KKCodeEditorView (Sections)

// Content reformat (declared in the public (Sections) category). Moved here
// from +Validation so the declaration + implementation share one category.
- (void)formatUsing:(NSString * (^)(NSString *))formatter {
  if (!formatter)
    return;
  NSString *current = [_textView.string copy];
  NSString *formatted = formatter(current);
  if (formatted.length == 0 || [formatted isEqualToString:current])
    return;
  NSRange full = NSMakeRange(0, current.length);
  if (![_textView shouldChangeTextInRange:full replacementString:formatted])
    return;
  NSUInteger caret = _textView.selectedRange.location;
  [_textView replaceCharactersInRange:full withString:formatted];
  [_textView didChangeText]; // fires textDidChange: -> debounce -> commit
  NSUInteger newLen = _textView.string.length;
  _textView.selectedRange = NSMakeRange(MIN(caret, newLen), 0);
  [self _runValidator]; // snappier than waiting for the debounce
}

- (void)setSections:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)sections {
  if (sections.count == 0)
    return;
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  NSMutableArray<NSString *> *codes = [NSMutableArray array];
  for (NSDictionary *s in sections) {
    [names addObject:[s[@"name"] isKindOfClass:[NSString class]] ? s[@"name"]
                                                                 : @""];
    [codes addObject:[s[@"code"] isKindOfClass:[NSString class]] ? s[@"code"]
                                                                 : @""];
  }
  _sectionNames = names;
  _sectionCodes = codes;
  if (_activeTab >= (NSInteger)codes.count)
    _activeTab = 0;
  _textView.string = _sectionCodes[_activeTab] ?: @"";
  [self _rebuildTabBar];
  [self _runValidator];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)sections {
  _sectionCodes[_activeTab] =
      [_textView.string copy]; // fold active tab's edits
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *out =
      [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)_sectionNames.count; i++)
    [out addObject:@{
      @"name" : _sectionNames[i],
      @"code" : _sectionCodes[i] ?: @""
    }];
  return out;
}

// `canUndo` is our "uncommitted local burst in progress" signal: the debounce
// commit clears the local undo, so a non-empty local stack means the user is
// mid-typing and an external re-apply would clobber them.

- (void)applyExternalSections:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)sections {
  if (!sections.count || [self _hasUncommittedTyping])
    return;
  if ([[self sections] isEqualToArray:sections])
    return;
  [self setSections:sections];
  [_textView.undoManager removeAllActions];
}

// A paste carrying `// #tab` markers is a whole multi-tab template arriving in
// one blob (what an AI assistant answers with, and what Option-clicking Copy
// Schema exports). Split it across the tabs instead of dropping it at the
// caret: each named tab is REPLACED wholesale, a named tab this editor doesn't
// have yet but its "+" menu offers is created, and any tab the blob doesn't
// name keeps what it had.
//
// The whole thing costs ONE host undo entry: the tab set is rewritten in
// memory, then committed with a single `onSectionsChange` - the same funnel a
// debounced typing burst uses, which reaches the host's lane replace once (see
// `_setLaneCodeSections:`). The local text-view undo is cleared for the same
// reason the debounce commit clears it: the paste is now durable host state, so
// Cmd-Z belongs to the host's stack, not to a half-tab of text.
//
// NO when the blob isn't multi-tab (no markers, or a marker naming a tab
// neither present nor offered) - then it is an ordinary paste into the caret,
// so nothing is ever silently dropped.
- (BOOL)_applyTabbedPaste:(NSString *)text {
  if (_sectionNames.count == 0)
    return NO;
  NSMutableArray<NSString *> *known = [_sectionNames mutableCopy];
  for (NSString *n in self.addableTabNames)
    if (![known containsObject:n])
      [known addObject:n];
  NSDictionary<NSString *, NSString *> *split =
      KKCodeSplitTabbedText(text, known);
  if (!split.count)
    return NO;

  _sectionCodes[_activeTab] = [_textView.string copy]; // fold live edits first
  for (NSString *name in known) {
    NSString *code = split[name];
    if (!code)
      continue;
    NSUInteger idx = [_sectionNames indexOfObject:name];
    if (idx == NSNotFound) {
      idx = (NSUInteger)[self _insertionIndexForTabNamed:name];
      [_sectionNames insertObject:name atIndex:idx];
      [_sectionCodes insertObject:code atIndex:idx];
      if (_activeTab >= (NSInteger)idx)
        _activeTab++;
    } else {
      _sectionCodes[idx] = code;
    }
  }
  // Land on the Image tab (the entry point, and where a `#template` error would
  // surface); a section set that doesn't name one falls back to the first.
  NSInteger target = 0;
  for (NSInteger i = 0; i < (NSInteger)_sectionNames.count; i++)
    if ([KKCodeTabCanonicalName(_sectionNames[i]) isEqualToString:@"image"]) {
      target = i;
      break;
    }
  _activeTab = target;
  _textView.string = _sectionCodes[target] ?: @"";
  [_debounce invalidate]; // this commit replaces any pending typing commit
  _debounce = nil;
  [_textView.undoManager removeAllActions];
  [self _rebuildTabBar];
  [self _runValidator];
  if (self.onChange)
    self.onChange(_textView.string);
  if (self.onSectionsChange)
    self.onSectionsChange([self sections]);
  return YES;
}

// A borderless text button styled for the strip.
- (NSButton *)_stripButton:(NSString *)title
                    action:(SEL)action
                       tag:(NSInteger)tag
                     color:(NSColor *)color
                      size:(CGFloat)size
                    weight:(NSFontWeight)weight {
  NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
  b.tag = tag;
  b.bordered = NO;
  b.attributedTitle = [[NSAttributedString alloc]
      initWithString:title
          attributes:@{
            NSForegroundColorAttributeName : color,
            NSFontAttributeName : [NSFont monospacedSystemFontOfSize:size
                                                              weight:weight]
          }];
  return b;
}

// Rebuild the tab strip: current sections (active bright + semibold), a close
// button on each added (non-first) tab, and a "+" menu of not-yet-added catalog
// names. Collapses to nothing when there's a single tab and nothing to add.
- (void)_rebuildTabBar {
  for (NSView *v in [_tabBar.arrangedSubviews copy]) {
    [_tabBar removeArrangedSubview:v];
    [v removeFromSuperview];
  }
  NSMutableArray<NSString *> *addable = [NSMutableArray array];
  for (NSString *n in self.addableTabNames)
    if (![_sectionNames containsObject:n])
      [addable addObject:n];
  BOOL trailing = (self.codeFormatter != nil) || (self.schemaProvider != nil);
  BOOL show = (_sectionNames.count > 1) || (addable.count > 0) || trailing;
  _tabBar.hidden = !show;
  _tabBarHeight.constant = show ? 22.0 : 0.0;
  // Fill only when a trailing button is present, so a spacer can push it to the
  // trailing edge; otherwise gravity-areas keeps the tabs left-packed at their
  // natural size.
  _tabBar.distribution = trailing ? NSStackViewDistributionFill
                                  : NSStackViewDistributionGravityAreas;
  if (!show)
    return;
  for (NSInteger i = 0; i < (NSInteger)_sectionNames.count; i++) {
    BOOL active = (i == _activeTab);
    [_tabBar addArrangedSubview:
                 [self _stripButton:_sectionNames[i]
                             action:@selector(_tabClicked:)
                                tag:i
                              color:active ? KKCodeText()
                                           : [KKCodeText()
                                                 colorWithAlphaComponent:0.45]
                               size:9.5
                             weight:active ? NSFontWeightSemibold
                                           : NSFontWeightRegular]];
    if (i > 0) // the first section is permanent; added tabs get a close button
      [_tabBar
          addArrangedSubview:[self
                                 _stripButton:@"✕"
                                       action:@selector(_tabCloseClicked:)
                                          tag:i
                                        color:[KKCodeText()
                                                  colorWithAlphaComponent:0.35]
                                         size:8.5
                                       weight:NSFontWeightRegular]];
  }
  if (addable.count > 0)
    [_tabBar
        addArrangedSubview:[self _stripButton:@"+"
                                       action:@selector(_plusClicked:)
                                          tag:-1
                                        color:[KKCodeText()
                                                  colorWithAlphaComponent:0.6]
                                         size:13.0
                                       weight:NSFontWeightMedium]];
  if (trailing) {
    // A greedy spacer (lowest hugging in a fill stack) eats the slack so the
    // trailing buttons sit at the trailing edge, whatever the tab count.
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_tabBar addArrangedSubview:spacer];
  }
  _schemaButton = nil;
  if (self.schemaProvider) {
    NSButton *schema =
        [self _stripButton:KKSchemaPlainTitle()
                    action:@selector(_copySchemaClicked:)
                       tag:-3
                     color:[KKCodeText() colorWithAlphaComponent:0.6]
                      size:9.5
                    weight:NSFontWeightMedium];
    schema.toolTip =
        KKLoc(@"Copy the template language reference for pasting into an AI "
              @"assistant. Option-click to include your current template.",
              @"Code editor: Copy Schema button tooltip.");
    // Pin the width to the LONGEST title it can wear (the Option variant) so
    // the live retitle - and the "Copied" flash - never reflows the strip.
    NSDictionary *attrs = [schema.attributedTitle attributesAtIndex:0
                                                     effectiveRange:NULL];
    CGFloat w = ceil([KKSchemaOptionTitle() sizeWithAttributes:attrs].width) +
                12.0; // NSButton's own text inset either side
    [schema.widthAnchor constraintEqualToConstant:w].active = YES;
    _schemaButton = schema;
    _schemaFlashing = NO;
    [_tabBar addArrangedSubview:schema];
    [self _applySchemaButtonTitle];
  }
  if (self.codeFormatter) {
    NSButton *fmt =
        [self _stripButton:KKLoc(@"Format", @"Code editor: reformat button.")
                    action:@selector(_formatClicked:)
                       tag:-2
                     color:[KKCodeText() colorWithAlphaComponent:0.6]
                      size:9.5
                    weight:NSFontWeightMedium];
    fmt.toolTip = KKLoc(@"Reformat the code to the house style",
                        @"Code editor: Format button tooltip.");
    [_tabBar addArrangedSubview:fmt];
  }
}

// Run the owner's formatter over the active section and replace the editor
// content with the result, as a single undoable edit. The change flows through
// the normal textDidChange debounce (stash / validate / commit), so the host
// persists the formatted text just like a typed edit. No-op when the formatter
// returns nil or text that is already formatted.

- (void)_tabClicked:(NSButton *)sender {
  [self _selectTab:sender.tag];
}

// Put the host's language reference on the clipboard. The strip has no other
// success affordance (the error-bar copy buttons flash nothing), so the button
// says so itself for a beat and then goes back to its title - a tab strip this
// small has no room for a checkmark that doesn't move the tabs.
// macOS-menu-style live retitle: while Option is physically down the button
// advertises the variant the click would actually perform. The "Copied" flash
// owns the title for its beat and is restored to the right one after.
- (void)_applySchemaButtonTitle {
  NSButton *b = _schemaButton;
  if (!b || _schemaFlashing)
    return;
  NSString *want = _optHeld ? KKSchemaOptionTitle() : KKSchemaPlainTitle();
  if ([b.attributedTitle.string isEqualToString:want])
    return;
  b.attributedTitle = [[NSAttributedString alloc]
      initWithString:want
          attributes:[b.attributedTitle attributesAtIndex:0
                                           effectiveRange:NULL]];
}

// Poll, don't listen: this editor lives in FCP's ViewBridge popover, where a
// flagsChanged never reaches a local monitor and the clicks that do arrive are
// synthesized with the modifiers stripped (same reason the click handler reads
// the HID state). The system-wide flag state is the only reliable source, so
// sample it while we're on screen and stop the moment we leave.
- (void)_startOptionModifierPolling {
  [self _stopOptionModifierPolling];
  __weak typeof(self) weakSelf = self; // never let the timer retain the editor
  _optPollTimer =
      [NSTimer scheduledTimerWithTimeInterval:0.1
                                      repeats:YES
                                        block:^(NSTimer *t) {
                                          [weakSelf _pollOptionModifier];
                                        }];
  // Common modes: the popover's own tracking loops would otherwise stall it.
  [NSRunLoop.currentRunLoop addTimer:_optPollTimer
                             forMode:NSRunLoopCommonModes];
}

- (void)_stopOptionModifierPolling {
  [_optPollTimer invalidate];
  _optPollTimer = nil;
  if (_optHeld) {
    _optHeld = NO;
    [self _applySchemaButtonTitle];
  }
}

- (void)_pollOptionModifier {
  BOOL held =
      (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) &
       kCGEventFlagMaskAlternate) != 0;
  if (held == _optHeld)
    return;
  _optHeld = held;
  [self _applySchemaButtonTitle];
}

- (void)_copySchemaClicked:(NSButton *)sender {
  if (!self.schemaProvider)
    return;
  // Option-click asks the host to append the user's own template. The click
  // itself may have been synthesized into this ViewBridge process (see the
  // popover gesture forwarding), which drops the modifier off the NSEvent, so
  // the system-wide HID state is the reliable read - NSApp's own event is kept
  // as the cheap first answer for a normally-delivered click.
  BOOL option =
      (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption) != 0 ||
      (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) &
       kCGEventFlagMaskAlternate) != 0;
  NSString *schema = self.schemaProvider(option ? [self sections] : nil);
  if (!schema.length)
    return;
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:schema forType:NSPasteboardTypeString];
  NSAttributedString *title = sender.attributedTitle;
  _schemaFlashing = YES; // outranks the live Option retitle while it shows
  sender.attributedTitle = [[NSAttributedString alloc]
      initWithString:KKLoc(@"Copied",
                           @"Code editor: Copy Schema button, after copying.")
          attributes:[title attributesAtIndex:0 effectiveRange:NULL]];
  __weak typeof(self) weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        // Only if the strip wasn't rebuilt under us (a tab add, a new lane) -
        // then this button is already gone and restoring it is a no-op anyway.
        sender.attributedTitle = title;
        typeof(self) strong = weakSelf;
        if (!strong || strong->_schemaButton != sender)
          return;
        strong->_schemaFlashing = NO;
        // Option may have been pressed or released during the flash.
        [strong _applySchemaButtonTitle];
      });
}

// "+" menu: the catalog names not yet present. Selecting one adds that section.
- (void)_plusClicked:(NSButton *)sender {
  NSMenu *menu = [[NSMenu alloc] init];
  for (NSString *n in self.addableTabNames) {
    if ([_sectionNames containsObject:n])
      continue;
    NSMenuItem *it =
        [[NSMenuItem alloc] initWithTitle:n
                                   action:@selector(_addTabFromMenu:)
                            keyEquivalent:@""];
    it.target = self;
    it.representedObject = n;
    [menu addItem:it];
  }
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0, NSHeight(sender.bounds))
                          inView:sender];
}

// Where a new tab named `name` belongs: catalog order among the extra tabs
// (section 0 stays first, whatever it is called).
- (NSInteger)_insertionIndexForTabNamed:(NSString *)name {
  NSInteger catIdx = (NSInteger)[self.addableTabNames indexOfObject:name];
  for (NSInteger i = 1; i < (NSInteger)_sectionNames.count; i++) {
    NSInteger ci =
        (NSInteger)[self.addableTabNames indexOfObject:_sectionNames[i]];
    if (ci != NSNotFound && ci > catIdx)
      return i;
  }
  return (NSInteger)_sectionNames.count;
}

- (void)_addTabFromMenu:(NSMenuItem *)item {
  NSString *name = item.representedObject;
  if (!name.length || [_sectionNames containsObject:name])
    return;
  NSInteger insertAt = [self _insertionIndexForTabNamed:name];
  _sectionCodes[_activeTab] = [_textView.string copy]; // stash current
  [_sectionNames insertObject:name atIndex:insertAt];
  [_sectionCodes insertObject:@"" atIndex:insertAt];
  _activeTab = insertAt;
  _textView.string = @"";
  [self _rebuildTabBar];
  [self _runValidator];
  if (self.onSectionsChange)
    self.onSectionsChange([self sections]);
}

- (void)_tabCloseClicked:(NSButton *)sender {
  NSInteger i = sender.tag;
  if (i <= 0 || i >= (NSInteger)_sectionNames.count)
    return; // never remove the first section's tab
  [_sectionNames removeObjectAtIndex:i];
  [_sectionCodes removeObjectAtIndex:i];
  if (_activeTab >= (NSInteger)_sectionNames.count)
    _activeTab = (NSInteger)_sectionNames.count - 1;
  if (_activeTab < 0)
    _activeTab = 0;
  _textView.string = _sectionCodes[_activeTab] ?: @"";
  [self _rebuildTabBar];
  [self _runValidator];
  if (self.onSectionsChange)
    self.onSectionsChange([self sections]);
}

// Switch the visible tab: stash the current text, load the target's,
// revalidate.
- (void)_selectTab:(NSInteger)i {
  if (i < 0 || i >= (NSInteger)_sectionCodes.count || i == _activeTab)
    return;
  _sectionCodes[_activeTab] = [_textView.string copy];
  _activeTab = i;
  _textView.string = _sectionCodes[i] ?: @"";
  [self _rebuildTabBar]; // restyle the active button
  [self _runValidator];
}

// Run the owner's validator over the current text and reflect the result: a
// one-line red bar and a flagged line, or clear both when it's valid / absent.

@end
