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
#import "KKGLSLSyntax.h" // strip colours
#import "KKLocalized.h"  // KKLoc
#import "KKTokens.h"     // sizing / weights
#import "NSColor+KKColors.h"

@interface KKCodeEditorView (SectionsPrivate)
- (void)_selectTab:(NSInteger)i;
- (NSButton *)_stripButton:(NSString *)title
                    action:(SEL)action
                       tag:(NSInteger)tag
                     color:(NSColor *)color
                      size:(CGFloat)size
                    weight:(NSFontWeight)weight;
@end

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
  BOOL show = (_sectionNames.count > 1) || (addable.count > 0) ||
              (self.codeFormatter != nil);
  _tabBar.hidden = !show;
  _tabBarHeight.constant = show ? 22.0 : 0.0;
  // Fill only when the Format button is present, so a spacer can push it to the
  // trailing edge; otherwise gravity-areas keeps the tabs left-packed at their
  // natural size.
  _tabBar.distribution = self.codeFormatter
                             ? NSStackViewDistributionFill
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
  if (self.codeFormatter) {
    // A greedy spacer (lowest hugging in a fill stack) eats the slack so the
    // Format button sits at the trailing edge, whatever the tab count.
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_tabBar addArrangedSubview:spacer];
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

- (void)_addTabFromMenu:(NSMenuItem *)item {
  NSString *name = item.representedObject;
  if (!name.length || [_sectionNames containsObject:name])
    return;
  // Insert keeping catalog order among the extra tabs (section 0 stays first).
  NSInteger catIdx = (NSInteger)[self.addableTabNames indexOfObject:name];
  NSInteger insertAt = (NSInteger)_sectionNames.count;
  for (NSInteger i = 1; i < (NSInteger)_sectionNames.count; i++) {
    NSInteger ci =
        (NSInteger)[self.addableTabNames indexOfObject:_sectionNames[i]];
    if (ci != NSNotFound && ci > catIdx) {
      insertAt = i;
      break;
    }
  }
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
