/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLTranspiler_Internal.h"
#import "MirageFrameOffsets.h" // KK_SHADER_MAX_FRAME_OFFSETS

@implementation KKGLSLTranspileResult {
  NSInteger _texIdx[4];
  NSInteger _sampIdx[4];
  NSInteger _nbrTexIdx[KK_SHADER_MAX_FRAME_OFFSETS];
  NSInteger _nbrSampIdx[KK_SHADER_MAX_FRAME_OFFSETS];
}
- (instancetype)init {
  if ((self = [super init])) {
    for (int i = 0; i < 4; i++) {
      _texIdx[i] = NSNotFound;
      _sampIdx[i] = NSNotFound;
    }
    for (int i = 0; i < KK_SHADER_MAX_FRAME_OFFSETS; i++) {
      _nbrTexIdx[i] = NSNotFound;
      _nbrSampIdx[i] = NSNotFound;
    }
    _fragmentName = @"main0";
    _vertexName = @"kkVertex";
  }
  return self;
}

// glslang error bodies read "'<token>' : <description>". Drop an empty token
// (the noisy "'' :" case); fold a real token inline.
static NSString *KKFoldErrorToken(NSString *raw) {
  static NSRegularExpression *tok;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    tok = [NSRegularExpression
        regularExpressionWithPattern:@"^'([^']*)'\\s*:\\s*(.*)$"
                             options:0
                               error:nil];
  });
  NSTextCheckingResult *tm =
      [tok firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
  if (!tm)
    return raw;
  NSString *token = [raw substringWithRange:[tm rangeAtIndex:1]];
  NSString *desc = [raw substringWithRange:[tm rangeAtIndex:2]];
  return token.length ? [NSString stringWithFormat:@"%@: %@", token, desc]
                      : desc;
}

// No parseable line: surface the first non-empty log line.
- (nullable NSString *)_firstLogLine {
  for (NSString *ln in [self.errorLog componentsSeparatedByString:@"\n"]) {
    NSString *t = [ln
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    if (t.length)
      return t;
  }
  return nil;
}

- (BOOL)firstError:(NSString **)outMessage line:(NSInteger *)outLine {
  if (!self.errorLog.length)
    return NO;
  // glslang: "ERROR: 0:23: 'x' : undeclared identifier". The middle number is
  // the (wrapped) line; map it back to the editor via userLineOffset.
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression regularExpressionWithPattern:
                                  @"(?:ERROR|WARNING):\\s*\\d+:(\\d+):\\s*(.*)"
                                                   options:0
                                                     error:nil];
  });
  NSTextCheckingResult *m =
      [re firstMatchInString:self.errorLog
                     options:0
                       range:NSMakeRange(0, self.errorLog.length)];
  if (!m) {
    if (outLine)
      *outLine = 0;
    if (outMessage)
      *outMessage = [self _firstLogLine];
    return YES;
  }

  NSInteger wrapped =
      [self.errorLog substringWithRange:[m rangeAtIndex:1]].integerValue;
  NSInteger editorLine = wrapped - self.userLineOffset;
  if (outLine)
    *outLine = editorLine > 0 ? editorLine : 0;
  if (outMessage) {
    NSString *raw = [[self.errorLog substringWithRange:[m rangeAtIndex:2]]
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
    raw = KKFoldErrorToken(raw);
    // A raw-GL paste whose entry point we shimmed, but that still trips
    // "undeclared identifier", almost always names a uniform the shim doesn't
    // know. Point the user at the fix instead of a bare compiler error.
    if (self.shimmedFromRawGL &&
        [raw rangeOfString:@"undeclared identifier"].location != NSNotFound)
      raw = [raw stringByAppendingString:
                     @" - looks like a uniform from another shader host; "
                     @"rename it to iChannel0 / iResolution / iTime"];
    *outMessage = raw;
  }
  return YES;
}

- (NSInteger)textureIndexForChannel:(NSUInteger)ch {
  return ch < 4 ? _texIdx[ch] : NSNotFound;
}
- (NSInteger)samplerIndexForChannel:(NSUInteger)ch {
  return ch < 4 ? _sampIdx[ch] : NSNotFound;
}
- (void)setTexture:(NSInteger)t
           sampler:(NSInteger)sm
        forChannel:(NSUInteger)ch {
  if (ch < 4) {
    _texIdx[ch] = t;
    _sampIdx[ch] = sm;
  }
}

- (NSInteger)textureIndexForNeighbor:(NSUInteger)i {
  return i < KK_SHADER_MAX_FRAME_OFFSETS ? _nbrTexIdx[i] : NSNotFound;
}
- (NSInteger)samplerIndexForNeighbor:(NSUInteger)i {
  return i < KK_SHADER_MAX_FRAME_OFFSETS ? _nbrSampIdx[i] : NSNotFound;
}
- (void)setTexture:(NSInteger)t
           sampler:(NSInteger)sm
       forNeighbor:(NSUInteger)i {
  if (i < KK_SHADER_MAX_FRAME_OFFSETS) {
    _nbrTexIdx[i] = t;
    _nbrSampIdx[i] = sm;
  }
}
@end
