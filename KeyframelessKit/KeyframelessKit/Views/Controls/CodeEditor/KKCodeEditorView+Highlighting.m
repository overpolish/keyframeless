/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Syntax colouring: grammar-driven token painting plus the directive-comment
// overlay (`// #kind` / `// @block` headers and their `key = value` bodies).
// Split out of KKCodeEditorView.m; reaches editor state via the @package ivars
// in KKCodeEditorView_Private.h.

#import "KKCodeEditorView_Private.h"
#import "KKCodeGrammar.h"
#import "KKCodeGutterView.h" // _lineGutter setNeedsDisplay:
#import "KKGLSLSyntax.h"

@interface KKCodeEditorView (HighlightingPrivate)
- (void)_colorDirectiveBodyRange:(NSRange)range
                       inStorage:(NSTextStorage *)ts
                          source:(NSString *)src;
- (void)_highlightDirectivesInStorage:(NSTextStorage *)ts
                               source:(NSString *)src;
@end

@implementation KKCodeEditorView (Highlighting)

- (void)_applyHighlighting {
  NSTextStorage *ts = _textView.textStorage;
  NSString *src = ts.string;
  NSRange full = NSMakeRange(0, src.length);
  [ts beginEditing];
  [_lineGutter setNeedsDisplay:YES]; // line count may have changed
  [ts removeAttribute:NSBackgroundColorAttributeName range:full];
  [ts addAttribute:NSForegroundColorAttributeName
             value:KKCodeText()
             range:full];
  if (_errorLine > 0) {
    NSRange lr = [self _rangeOfLine:_errorLine in:src];
    if (lr.location != NSNotFound)
      [ts addAttribute:NSBackgroundColorAttributeName
                 value:[KKCodeError() colorWithAlphaComponent:0.16]
                 range:lr];
  }
  // Syntax highlighting is grammar-driven: the editor paints each tokenizer
  // match through a KKCodeGrammar, so a new language is a new grammar object,
  // not another branch here.
  id<KKCodeGrammar> grammar = (self.syntax == KKCodeSyntaxExpression)
                                  ? KKCodeGrammars.expressionGrammar
                                  : KKCodeGrammars.glslGrammar;
  NSSet<NSString *> *declared = [grammar declaredIdentifiersInSource:src];
  // A shader's own `uniform` names, kept on the instance so the directive-body
  // highlighter reuses them for `@osc` uniform references (empty for grammars
  // without declared identifiers, e.g. expressions).
  if (grammar.highlightsDirectives)
    _glslDeclaredUniforms = declared;
  [[grammar tokenizer]
      enumerateMatchesInString:src
                       options:0
                         range:full
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags,
                                 BOOL *stop) {
                      NSRange r = NSMakeRange(NSNotFound, 0);
                      NSColor *color = [grammar colorForMatch:m
                                                     inSource:src
                                          declaredIdentifiers:declared
                                                     outRange:&r];
                      if (color && r.location != NSNotFound)
                        [ts addAttribute:NSForegroundColorAttributeName
                                   value:color
                                   range:r];
                    }];
  // Overlay directive colouring on the grey comments: `// #kind` / `// @block`
  // headers + their `key = value` attributes read as structured annotations.
  if (grammar.highlightsDirectives)
    [self _highlightDirectivesInStorage:ts source:src];
  [ts endEditing];
}

// A directive HEADER comment: `// #kind ...` / `// @block ...`. Group 1 is the
// `#kind` / `@block` token. `^` anchors it to the line start (after indent).
static NSRegularExpression *KKDirectiveHeaderRE(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"^\\s*//\\s*([#@][A-Za-z_]\\w*)"
                             options:0
                               error:nil];
  });
  return re;
}

// The colourable pieces after a directive header (and on each `key = value`
// block-continuation line): group 1 an attribute/field KEY (a word right before
// `=`), 2 a quoted string, 3 a number.
//
// Group 4 spans internal hyphens (`color-transform`), so a hyphenated enum value
// is ONE token and can match the keyword set. Splitting it left both halves
// unknown and painted the value flat. The hyphen must be followed by a letter,
// so a number's leading `-` still belongs to group 3.
static NSRegularExpression *KKDirectiveBodyRE(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"([A-Za-z_]\\w*)(?=\\s*=(?!=))" // 1 key
                                     @"|(\"(?:[^\"\\\\]|\\\\.)*\")"   // 2 str
                                     @"|(?<![\\w.])(-?\\d+\\.?\\d*)"  // 3 num
                                     @"|([A-Za-z_]\\w*(?:-[A-Za-z]\\w*)*)" // 4
                             options:0
                               error:nil];
  });
  return re;
}

// Colour keys/strings/numbers in `range` (a directive line's body). `ts`/`src`
// as in -_applyHighlighting; `range` is in `src` coordinates.
- (void)_colorDirectiveBodyRange:(NSRange)range
                       inStorage:(NSTextStorage *)ts
                          source:(NSString *)src {
  if (range.length == 0)
    return;
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  [KKDirectiveBodyRE()
      enumerateMatchesInString:src
                       options:0
                         range:range
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags,
                                 BOOL *stop) {
                      NSColor *color = nil;
                      NSRange r = [m rangeAtIndex:1];
                      if (r.location != NSNotFound) {
                        color = KKCodeUniform(); // key= (orange)
                      } else if ((r = [m rangeAtIndex:2]).location !=
                                 NSNotFound) {
                        color = KKCodeString();
                      } else if ((r = [m rangeAtIndex:3]).location !=
                                 NSNotFound) {
                        color = KKCodeNumber();
                      } else if ((r = [m rangeAtIndex:4]).location !=
                                 NSNotFound) {
                        // A value identifier (tr, pad, vec2…): a function call
                        // when the next non-space char is `(`; a known keyword
                        // (enum value / boolean / bare flag) coral; else a
                        // plain value - either way NOT the flat comment grey.
                        NSUInteger j = NSMaxRange(r);
                        while (j < src.length &&
                               [ws characterIsMember:[src characterAtIndex:j]])
                          j++;
                        NSString *w = [src substringWithRange:r];
                        if (j < src.length && [src characterAtIndex:j] == '(')
                          color = KKCodeFunction();
                        else if ([self.directiveKeywords containsObject:w])
                          color = KKCodeKeyword();
                        else if ([self->_glslDeclaredUniforms containsObject:w])
                          color = KKCodeUniform(); // `@osc` uniform reference
                        else
                          color = KKCodeText();
                      }
                      if (color && r.location != NSNotFound)
                        [ts addAttribute:NSForegroundColorAttributeName
                                   value:color
                                   range:r];
                    }];
}

- (void)_highlightDirectivesInStorage:(NSTextStorage *)ts
                               source:(NSString *)src {
  NSRegularExpression *header = KKDirectiveHeaderRE();
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  __block BOOL inBlock =
      NO; // inside an open `@block` (its `key = value` lines)
  [src enumerateSubstringsInRange:NSMakeRange(0, src.length)
                          options:NSStringEnumerationByLines
                       usingBlock:^(NSString *line, NSRange lineRange,
                                    NSRange enclosing, BOOL *stop) {
                         NSRange slashes = [line rangeOfString:@"//"];
                         if (slashes.location == NSNotFound) {
                           inBlock =
                               NO; // a non-comment line closes any open block
                           return;
                         }
                         NSTextCheckingResult *h = [header
                             firstMatchInString:line
                                        options:0
                                          range:NSMakeRange(0, line.length)];
                         if (h) {
                           NSRange tok = [h rangeAtIndex:1];
                           NSString *token = [line substringWithRange:tok];
                           // Only a KNOWN directive kind greens + opens a
                           // block; an unknown / half-typed token (`// #alp`)
                           // stays a plain grey comment. A nil set keeps the
                           // old lexical behaviour (green any `// #word` / `//
                           // @word`).
                           if (self.directiveKinds &&
                               ![self.directiveKinds containsObject:token]) {
                             inBlock = NO;
                             return;
                           }
                           [ts addAttribute:NSForegroundColorAttributeName
                                      value:KKCodeDirective() // green: a
                                                              // directive, not
                                                              // a code keyword
                                      range:NSMakeRange(lineRange.location +
                                                            tok.location,
                                                        tok.length)];
                           // `@block` opens a multi-line block (its indented
                           // `key = value` fields); a `#kind` directive is
                           // single-line.
                           inBlock = [token hasPrefix:@"@"];
                           NSUInteger bodyStart = NSMaxRange(tok);
                           [self
                               _colorDirectiveBodyRange:NSMakeRange(
                                                            lineRange.location +
                                                                bodyStart,
                                                            line.length -
                                                                bodyStart)
                                              inStorage:ts
                                                 source:src];
                           return;
                         }
                         if (!inBlock)
                           return;
                         // A block continuation line: the comment body after
                         // `//`. A blank comment (or `}`) ends the block;
                         // otherwise colour its key = value.
                         NSUInteger bs = NSMaxRange(slashes);
                         NSString *body = [[line substringFromIndex:bs]
                             stringByTrimmingCharactersInSet:ws];
                         if (body.length == 0 || [body isEqualToString:@"}"]) {
                           inBlock = NO;
                           return;
                         }
                         [self _colorDirectiveBodyRange:NSMakeRange(
                                                            lineRange.location +
                                                                bs,
                                                            line.length - bs)
                                              inStorage:ts
                                                 source:src];
                       }];
}

- (void)textStorage:(NSTextStorage *)textStorage
    didProcessEditing:(NSTextStorageEditActions)editedMask
                range:(NSRange)editedRange
       changeInLength:(NSInteger)delta {
  // Only character edits change tokens (our own colour writes are attribute
  // edits). Coalesce and defer so we don't mutate attributes mid-processing.
  if (!(editedMask & NSTextStorageEditedCharacters) || _highlightScheduled)
    return;
  _highlightScheduled = YES;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_highlightScheduled = NO;
    [s _applyHighlighting];
  });
}

@end
