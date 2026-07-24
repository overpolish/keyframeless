/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Inline autocomplete: the caret-word completion list (GLSL via the host
// completionProvider, Expression via KKExprCatalog), its keyboard navigation,
// and the overlay lifecycle. Split out of KKCodeEditorView.m; reaches editor
// state via the @package ivars in KKCodeEditorView_Private.h.

#import "KKCodeEditorSubviews.h" // _KKExprCompletionView
#import "KKCodeEditorView_Private.h"
#import "KKGLSLSyntax.h" // KKExprCatalog
#import "KKLocalized.h"  // KKLoc

@interface KKCodeEditorView (AutocompletePrivate)
- (NSRange)_completionWordRange;
- (void)_showCompletion;
- (BOOL)_moveCompletionBy:(NSInteger)delta;
- (BOOL)_acceptCompletion;
@end

@implementation KKCodeEditorView (Autocomplete)

- (BOOL)textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (_completion.superview) {
    if (commandSelector == @selector(moveDown:))
      return [self _moveCompletionBy:1];
    if (commandSelector == @selector(moveUp:))
      return [self _moveCompletionBy:-1];
    if (commandSelector == @selector(insertNewline:) ||
        commandSelector == @selector(insertTab:))
      return [self _acceptCompletion];
    if (commandSelector == @selector(cancelOperation:)) {
      [self _hideCompletion];
      return YES;
    }
    if (commandSelector == @selector(moveLeft:) ||
        commandSelector == @selector(moveRight:) ||
        commandSelector == @selector(moveToBeginningOfLine:) ||
        commandSelector == @selector(moveToEndOfLine:) ||
        commandSelector == @selector(deleteBackward:))
      [self _hideCompletion]; // then fall through to perform the edit
  }
  if (commandSelector == @selector(cancelOperation:)) {
    [textView.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

// The identifier prefix under the caret (empty selection), or a not-found
// range.
- (NSRange)_completionWordRange {
  NSRange sel = _textView.selectedRange;
  if (sel.length > 0)
    return NSMakeRange(NSNotFound, 0);
  NSString *s = _textView.string;
  NSUInteger caret = sel.location;
  static NSCharacterSet *idSet;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    idSet = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
  });
  NSUInteger start = caret;
  while (start > 0 && [idSet characterIsMember:[s characterAtIndex:start - 1]])
    start--;
  if (start == caret)
    return NSMakeRange(NSNotFound, 0);
  unichar first = [s characterAtIndex:start];
  if (first >= '0' && first <= '9') // a numeric literal, not an identifier
    return NSMakeRange(NSNotFound, 0);
  return NSMakeRange(start, caret - start);
}

static BOOL KKIsExprIdentChar(unichar c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') || c == '_';
}

// Vector-swizzle completions for an expression `value` / `${ref}` / call
// result, filtered by the partial after the dot. Generic (no component count) -
// the user picks the ones their vector actually has.
static NSArray<NSDictionary<NSString *, NSString *> *> *
KKSwizzleCompletionItems(NSString *prefix) {
  static NSArray *all;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSDictionary * (^S)(NSString *, NSString *) = ^(NSString *n, NSString *d) {
      return @{
        @"name" : n,
        @"signature" : n,
        @"desc" : KKLoc(d, @"Code editor: help for a vector swizzle "
                           @"component (.x / .rgba …)."),
        @"insert" : n
      };
    };
    all = @[
      S(@"x", @"1st component (or red)."),
      S(@"y", @"2nd component (or green)."),
      S(@"z", @"3rd component (or blue)."),
      S(@"w", @"4th component (or alpha)."), S(@"r", @"Red (1st component)."),
      S(@"g", @"Green (2nd component)."), S(@"b", @"Blue (3rd component)."),
      S(@"a", @"Alpha (4th component)."),
      S(@"xy", @"The first two components."),
      S(@"xyz", @"The first three components."),
      S(@"xyzw", @"All four components."), S(@"rgb", @"Red, green, blue."),
      S(@"rgba", @"Red, green, blue, alpha.")
    ];
  });
  if (prefix.length == 0)
    return all;
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary<NSString *, NSString *> *e in all)
    if ([e[@"name"] rangeOfString:prefix
                          options:NSCaseInsensitiveSearch | NSAnchoredSearch]
            .location == 0)
      [out addObject:e];
  if (out.count == 1 &&
      [out[0][@"name"] caseInsensitiveCompare:prefix] == NSOrderedSame)
    return @[];
  return out;
}

// Recompute the autocomplete list from the word under the caret. Expression
// syntax only, only while the editor is focused. Hides when nothing matches (or
// the only match is already fully typed).
- (void)_updateCompletions {
  if (self.window.firstResponder != _textView) {
    [self _hideCompletion];
    return;
  }
  // GLSL mode with a host provider: it owns the vocabulary + context (a
  // shader's `//` directives, GLSL builtins, declared uniforms) and returns the
  // filtered items + the range the pick replaces. Only fires when the caret has
  // no selection (a live word/context, like the expression path).
  if (self.syntax == KKCodeSyntaxGLSL && self.completionProvider) {
    if (_textView.selectedRange.length > 0) {
      [self _hideCompletion];
      return;
    }
    NSRange replace = NSMakeRange(NSNotFound, 0);
    NSArray<NSDictionary<NSString *, NSString *> *> *items =
        self.completionProvider(_textView.string,
                                _textView.selectedRange.location, &replace);
    if (items.count == 0 || replace.location == NSNotFound) {
      [self _hideCompletion];
      return;
    }
    _completionWord = replace;
    _completionItems = items;
    if (_completionIndex >= (NSInteger)items.count)
      _completionIndex = 0;
    [self _showCompletion];
    return;
  }
  if (self.syntax != KKCodeSyntaxExpression) {
    [self _hideCompletion];
    return;
  }
  // Link-reference completion: the caret inside a `${...` token (no `}` or
  // newline between the opener and the caret) offers the discovered sources,
  // host-supplied and filtered by the typed partial. Checked before swizzle /
  // word completion so a partial like `${Cl` never falls through to the
  // function catalog.
  if (self.linkCompletionProvider && _textView.selectedRange.length == 0) {
    NSString *src = _textView.string;
    NSUInteger caret = _textView.selectedRange.location;
    NSUInteger open = NSNotFound;
    for (NSUInteger i = caret; i >= 2; i--) {
      unichar c = [src characterAtIndex:i - 1];
      if (c == '}' || c == '\n')
        break;
      if (c == '{' && [src characterAtIndex:i - 2] == '$') {
        open = i;
        break;
      }
    }
    if (open != NSNotFound) {
      NSArray<NSDictionary<NSString *, NSString *> *> *items =
          self.linkCompletionProvider(
              [src substringWithRange:NSMakeRange(open, caret - open)]);
      if (items.count == 0) {
        [self _hideCompletion];
        return;
      }
      // When the caret sits inside an already-closed ref, accepting replaces
      // the WHOLE token tail (through its `}`), so a pick swaps the ref
      // instead of splicing into it.
      NSUInteger end = caret;
      while (end < src.length) {
        unichar c = [src characterAtIndex:end];
        if (c == '\n' || c == '$')
          break;
        end++;
        if (c == '}')
          break;
      }
      BOOL closed = end > caret && [src characterAtIndex:end - 1] == '}';
      _completionWord = NSMakeRange(open, (closed ? end : caret) - open);
      _completionItems = items;
      if (_completionIndex >= (NSInteger)items.count)
        _completionIndex = 0;
      [self _showCompletion];
      return;
    }
  }
  // Vector swizzle: a `.` right after a value / `${ref}` / `)` offers the
  // component accessors (`.x`, `.rgba`, …). Handled before the word lookup so
  // an empty partial (`value.`) still shows the list.
  if (_textView.selectedRange.length == 0) {
    NSString *src = _textView.string;
    NSUInteger caret = _textView.selectedRange.location;
    NSUInteger sw = caret;
    while (sw > 0 && KKIsExprIdentChar([src characterAtIndex:sw - 1]))
      sw--;
    if (sw > 0 && [src characterAtIndex:sw - 1] == '.') {
      unichar b = sw >= 2 ? [src characterAtIndex:sw - 2] : 0;
      if (KKIsExprIdentChar(b) || b == ')' || b == '}') {
        NSArray *items = KKSwizzleCompletionItems(
            [src substringWithRange:NSMakeRange(sw, caret - sw)]);
        if (items.count) {
          _completionWord = NSMakeRange(sw, caret - sw);
          _completionItems = items;
          if (_completionIndex >= (NSInteger)items.count)
            _completionIndex = 0;
          [self _showCompletion];
        } else {
          [self _hideCompletion];
        }
        return;
      }
    }
  }
  NSRange word = [self _completionWordRange];
  if (word.location == NSNotFound) {
    [self _hideCompletion];
    return;
  }
  NSString *prefix = [_textView.string substringWithRange:word];
  NSMutableArray *matches = [NSMutableArray array];
  for (NSDictionary<NSString *, NSString *> *e in KKExprCatalog())
    if ([e[@"name"] rangeOfString:prefix
                          options:NSCaseInsensitiveSearch | NSAnchoredSearch]
            .location == 0)
      [matches addObject:e];
  if (matches.count == 0 ||
      (matches.count == 1 &&
       [matches[0][@"name"] caseInsensitiveCompare:prefix] == NSOrderedSame)) {
    [self _hideCompletion];
    return;
  }
  _completionWord = word;
  _completionItems = matches;
  if (_completionIndex >= (NSInteger)matches.count)
    _completionIndex = 0;
  [self _showCompletion];
}

// Position the overlay just under the caret in the window's content view (not a
// child of the clipped editor), so it can extend past the one-line editor.
// Flips above the caret when it would fall off the bottom.
- (void)_showCompletion {
  NSView *content = self.window.contentView;
  if (!content) {
    [self _hideCompletion];
    return;
  }
  if (!_completion) {
    _completion = [[_KKExprCompletionView alloc] initWithFrame:NSZeroRect];
    __weak typeof(self) weak = self;
    _completion.onPick = ^(NSInteger index) {
      __strong typeof(weak) s = weak;
      if (!s)
        return;
      s->_completionIndex = index;
      [s _acceptCompletion];
    };
  }
  _completion.items = _completionItems;
  _completion.selectedIndex = _completionIndex;

  // Caret rect -> content-view coords (handles the content view's flippedness),
  // then place the list just UNDER the text line, flipping above only if it
  // would fall off the bottom edge.
  NSRect caretScreen = [_textView
      firstRectForCharacterRange:NSMakeRange(_completionWord.location, 0)
                     actualRange:NULL];
  NSRect caret =
      [content convertRect:[self.window convertRectFromScreen:caretScreen]
                  fromView:nil];
  CGFloat w = [_KKExprCompletionView preferredWidth];
  CGFloat h = [_completion fittingHeight];
  CGFloat gap = 4.0;
  CGFloat x = caret.origin.x - 6.0;
  CGFloat
      y; // one line below the caret, in whichever vertical direction is "down"
  if (content.isFlipped) {
    y = NSMaxY(caret) + gap;
    if (y + h > NSMaxY(content.bounds) - 4.0)
      y = caret.origin.y - gap - h;
  } else {
    y = caret.origin.y - gap - h;
    if (y < 4.0)
      y = NSMaxY(caret) + gap;
  }
  if (x + w > NSMaxX(content.bounds) - 4.0)
    x = NSMaxX(content.bounds) - 4.0 - w;
  if (x < 4.0)
    x = 4.0;
  _completion.frame = NSMakeRect(x, y, w, h);
  if (_completion.superview != content)
    [content addSubview:_completion positioned:NSWindowAbove relativeTo:nil];
  [_completion setNeedsDisplay:YES];
}

- (void)_hideCompletion {
  [_completion removeFromSuperview];
  _completionItems = nil;
  _completionIndex = 0;
  _completionWord = NSMakeRange(NSNotFound, 0);
}

- (BOOL)_moveCompletionBy:(NSInteger)delta {
  NSInteger n = (NSInteger)_completionItems.count;
  if (n == 0)
    return NO;
  _completionIndex = (_completionIndex + delta + n) % n;
  _completion.selectedIndex = _completionIndex;
  return YES;
}

- (BOOL)_acceptCompletion {
  if (_completionWord.location == NSNotFound ||
      _completionIndex >= (NSInteger)_completionItems.count)
    return NO;
  NSString *insert = _completionItems[_completionIndex][@"insert"];
  NSRange r = _completionWord;
  [self _hideCompletion];
  if (![_textView shouldChangeTextInRange:r replacementString:insert])
    return YES;
  [_textView replaceCharactersInRange:r withString:insert];
  [_textView setSelectedRange:NSMakeRange(r.location + insert.length, 0)];
  [_textView didChangeText]; // commits through the debounce like typed text
  return YES;
}

// Blur (click-away / Esc) closes the autocomplete list.
- (void)textDidEndEditing:(NSNotification *)notification {
  [self _hideCompletion];
}

// NOTE: no -viewWillMoveToWindow: here. A category implementation REPLACES
// the main class's (which carries the window-undo-manager clear that guards
// the rebuild -> Cmd-Z dangling-target crash); the completion-overlay drop
// lives in the main class's override instead.

// Every edit (typed or programmatic) routes through here before it commits, so
// the selection change it causes is flagged as an edit rather than a caret
// move. Also hosts the `${` auto-close: an unclosed token reads as a syntax
// error the whole time the ref is being typed, so typing the `{` of `${`
// inserts the closing `}` too (caret between), and typing `}` over the
// auto-inserted one steps past it instead of doubling (Expression mode only -
// GLSL nests braces for real).
- (BOOL)textView:(NSTextView *)textView
    shouldChangeTextInRange:(NSRange)affectedCharRange
          replacementString:(NSString *)replacementString {
  _completionEditInFlight = YES;
  if (affectedCharRange.length == 0 && replacementString.length == 1) {
    unichar ch = [replacementString characterAtIndex:0];
    NSString *s = textView.string;
    if (ch == '{' && affectedCharRange.location > 0 &&
        [s characterAtIndex:affectedCharRange.location - 1] == '$') {
      if ([textView shouldChangeTextInRange:affectedCharRange
                          replacementString:@"{}"]) {
        [textView replaceCharactersInRange:affectedCharRange withString:@"{}"];
        [textView
            setSelectedRange:NSMakeRange(affectedCharRange.location + 1, 0)];
        [textView didChangeText];
      }
      return NO;
    }
    if (self.syntax == KKCodeSyntaxExpression && ch == '}' &&
        affectedCharRange.location < s.length &&
        [s characterAtIndex:affectedCharRange.location] == '}') {
      _completionEditInFlight = NO; // a real caret move - let it close the list
      [textView
          setSelectedRange:NSMakeRange(affectedCharRange.location + 1, 0)];
      return NO;
    }
  }
  return YES;
}

// A caret move (mouse click, or any selection change not caused by an edit)
// dismisses the completion list - matching the arrow-key/line-nav dismissal in
// doCommandBySelector. Consume the edit flag once so a typing edit's own
// selection change refreshes the list (via textDidChange) instead of closing
// it.
- (void)textViewDidChangeSelection:(NSNotification *)notification {
  BOOL fromEdit = _completionEditInFlight;
  _completionEditInFlight = NO;
  if (fromEdit)
    return;
  if (_completion.superview)
    [self _hideCompletion];
}

@end
