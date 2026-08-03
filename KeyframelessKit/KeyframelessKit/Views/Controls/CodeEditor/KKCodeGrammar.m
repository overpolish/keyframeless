/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeGrammar.h"

#import "KKGLSLSyntax.h" // tokenizers, word colours, theme

// GLSL: comment / preprocessor / number / identifier, where an unknown
// identifier is a function call when followed by `(`, else one of the source's
// own uniforms, else default text. Carries the `// #kind` / `// @osc` directive
// overlay.
@interface KKGLSLGrammar : NSObject <KKCodeGrammar>
@end

@implementation KKGLSLGrammar

- (NSRegularExpression *)tokenizer {
  return KKGLSLTokenizer();
}

- (BOOL)highlightsDirectives {
  return YES;
}

- (NSSet<NSString *> *)declaredIdentifiersInSource:(NSString *)source {
  return KKGLSLDeclaredUniforms(source);
}

- (NSColor *)colorForMatch:(NSTextCheckingResult *)m
                  inSource:(NSString *)src
       declaredIdentifiers:(NSSet<NSString *> *)declared
                  outRange:(NSRange *)outRange {
  NSRange r = [m rangeAtIndex:1];
  if (r.location != NSNotFound) {
    *outRange = r;
    return KKCodeComment();
  }
  if ((r = [m rangeAtIndex:2]).location != NSNotFound) {
    *outRange = r;
    return KKCodeKeyword(); // #directive
  }
  if ((r = [m rangeAtIndex:3]).location != NSNotFound) {
    *outRange = r;
    return KKCodeNumber();
  }
  if ((r = [m rangeAtIndex:4]).location != NSNotFound) {
    *outRange = r;
    NSString *w = [src substringWithRange:r];
    NSColor *color = KKGLSLWordColor(w);
    if (!color) {
      // Not a known word: a function call if the next non-space char is `(`, a
      // declared uniform -> orange, else a plain variable (default text).
      NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
      NSUInteger j = NSMaxRange(r);
      while (j < src.length && [ws characterIsMember:[src characterAtIndex:j]])
        j++;
      if (j < src.length && [src characterAtIndex:j] == '(')
        color = KKCodeFunction();
      else if ([declared containsObject:w])
        color = KKCodeUniform();
    }
    return color;
  }
  *outRange = NSMakeRange(NSNotFound, 0);
  return nil;
}

@end

// Expression grammar: `${ref}` (orange, an external input), number, identifier
// (built-in fn -> purple, var/const -> coral, else default). No directives, no
// declared identifiers.
@interface KKExprGrammar : NSObject <KKCodeGrammar>
@end

@implementation KKExprGrammar

- (NSRegularExpression *)tokenizer {
  return KKExprTokenizer();
}

- (BOOL)highlightsDirectives {
  return NO;
}

- (NSSet<NSString *> *)declaredIdentifiersInSource:(NSString *)source {
  return [NSSet set];
}

- (NSColor *)colorForMatch:(NSTextCheckingResult *)m
                  inSource:(NSString *)src
       declaredIdentifiers:(NSSet<NSString *> *)declared
                  outRange:(NSRange *)outRange {
  NSRange r = [m rangeAtIndex:1];
  if (r.location != NSNotFound) {
    *outRange = r;
    return KKCodeUniform(); // ${ref}
  }
  if ((r = [m rangeAtIndex:2]).location != NSNotFound) {
    *outRange = r;
    return KKCodeNumber();
  }
  if ((r = [m rangeAtIndex:3]).location != NSNotFound) {
    *outRange = r;
    return KKExprWordColor([src substringWithRange:r]);
  }
  *outRange = NSMakeRange(NSNotFound, 0);
  return nil;
}

@end

@implementation KKCodeGrammars

+ (id<KKCodeGrammar>)glslGrammar {
  static KKGLSLGrammar *g;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g = [KKGLSLGrammar new];
  });
  return g;
}

+ (id<KKCodeGrammar>)expressionGrammar {
  static KKExprGrammar *g;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g = [KKExprGrammar new];
  });
  return g;
}

@end
