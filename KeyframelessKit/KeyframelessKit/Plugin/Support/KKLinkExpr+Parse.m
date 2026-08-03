/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Source text -> KKExprNode tree. The recursive-descent parser plus the two
// class methods that front it: +compile: (build a KKLinkExpr) and
// +errorCharRangeForSource: (locate the first parse error for the editor).

#import "KKLinkExpr_Private.h"

#import <math.h>

typedef struct {
  const char *s;
  long len;
  long pos;
  BOOL error;
  long errPos; // byte offset where the FIRST error was raised
  NSString *errMsg;
  __unsafe_unretained NSMutableSet<NSString *> *refs; // collected during parse
  __unsafe_unretained NSSet<NSString *> *allowedVars; // OSC bare-var allow-list
} KKExprParser;

static void KKExprFail(KKExprParser *p, NSString *msg) {
  if (!p->error) {
    p->error = YES;
    p->errMsg = msg;
    p->errPos = p->pos;
  }
}

static void KKExprSkipSpace(KKExprParser *p) {
  while (p->pos < p->len) {
    char c = p->s[p->pos];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
      p->pos++;
    else
      break;
  }
}

static char KKExprPeek(KKExprParser *p) {
  KKExprSkipSpace(p);
  return p->pos < p->len ? p->s[p->pos] : '\0';
}

static KKExprNode *KKExprParseExpr(KKExprParser *p); // fwd

// Reads a run of [A-Za-z0-9_] starting at pos (no leading space skip).
static NSString *KKExprReadIdent(KKExprParser *p) {
  long start = p->pos;
  while (p->pos < p->len) {
    char c = p->s[p->pos];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '_')
      p->pos++;
    else
      break;
  }
  return [[NSString alloc] initWithBytes:p->s + start
                                  length:(NSUInteger)(p->pos - start)
                                encoding:NSUTF8StringEncoding];
}

static KKExprNode *KKExprParseAtom(KKExprParser *p) {
  char c = KKExprPeek(p);
  if (c == '\0') {
    KKExprFail(p, @"unexpected end of expression");
    return nil;
  }
  // parenthesised
  if (c == '(') {
    p->pos++;
    KKExprNode *inner = KKExprParseExpr(p);
    if (KKExprPeek(p) != ')') {
      KKExprFail(p, @"expected ')'");
      return nil;
    }
    p->pos++;
    return inner;
  }
  // ${name} reference
  if (c == '$') {
    p->pos++;
    if (KKExprPeek(p) != '{') {
      KKExprFail(p, @"expected '{' after '$'");
      return nil;
    }
    p->pos++;
    long start = p->pos;
    while (p->pos < p->len && p->s[p->pos] != '}')
      p->pos++;
    if (p->pos >= p->len) {
      KKExprFail(p, @"unterminated ${...}");
      return nil;
    }
    NSString *nm = [[NSString alloc] initWithBytes:p->s + start
                                            length:(NSUInteger)(p->pos - start)
                                          encoding:NSUTF8StringEncoding];
    nm = [nm stringByTrimmingCharactersInSet:[NSCharacterSet
                                                 whitespaceCharacterSet]];
    p->pos++; // consume '}'
    if (nm.length == 0) {
      KKExprFail(p, @"empty ${} reference");
      return nil;
    }
    [p->refs addObject:nm];
    KKExprNode *n = [KKExprNode new];
    n->kind = KKNodeRef;
    n->name = nm;
    return n;
  }
  // number
  if ((c >= '0' && c <= '9') || c == '.') {
    char *end = NULL;
    double val = strtod(p->s + p->pos, &end);
    if (end == p->s + p->pos) {
      KKExprFail(p, @"bad number");
      return nil;
    }
    p->pos = end - p->s;
    KKExprNode *n = [KKExprNode new];
    n->kind = KKNodeNum;
    n->num = val;
    return n;
  }
  // identifier: variable, constant, or function call
  if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
    KKExprSkipSpace(p);
    NSString *ident = KKExprReadIdent(p);
    if (KKExprPeek(p) == '(') {
      p->pos++; // '('
      NSMutableArray<KKExprNode *> *args = [NSMutableArray array];
      if (KKExprPeek(p) != ')') {
        while (1) {
          KKExprNode *arg = KKExprParseExpr(p);
          if (p->error)
            return nil;
          [args addObject:arg];
          char sep = KKExprPeek(p);
          if (sep == ',') {
            p->pos++;
            continue;
          }
          break;
        }
      }
      if (KKExprPeek(p) != ')') {
        KKExprFail(p, @"expected ')' in call");
        return nil;
      }
      p->pos++;
      KKExprNode *n = [KKExprNode new];
      n->kind = KKNodeCall;
      n->name = ident;
      n->args = args;
      return n;
    }
    KKExprNode *n = [KKExprNode new];
    if ([ident isEqualToString:@"value"])
      n->kind = KKNodeValue;
    else if ([ident isEqualToString:@"t"])
      n->kind = KKNodeTime;
    else if ([ident isEqualToString:@"progress"])
      n->kind = KKNodeProgress;
    else if ([ident isEqualToString:@"ct"])
      n->kind = KKNodeClipTime;
    else if ([ident isEqualToString:@"pi"]) {
      n->kind = KKNodeNum;
      n->num = M_PI;
    } else if ([ident isEqualToString:@"tau"]) {
      n->kind = KKNodeNum;
      n->num = 2.0 * M_PI;
    } else if ([ident isEqualToString:@"e"]) {
      n->kind = KKNodeNum;
      n->num = M_E;
    } else if ([p->allowedVars containsObject:ident]) {
      n->kind = KKNodeVar;
      n->name = ident;
    } else {
      KKExprFail(p, [NSString stringWithFormat:@"unknown name '%@'", ident]);
      return nil;
    }
    return n;
  }
  KKExprFail(p, [NSString stringWithFormat:@"unexpected '%c'", c]);
  return nil;
}

// Is `name` a rect member accessor (`rect(min, max)` is a vec4 of
// minX, minY, maxX, maxY; these read it as a rect)?
static BOOL KKExprIsRectMember(NSString *name) {
  return [name isEqualToString:@"min"] || [name isEqualToString:@"max"] ||
         [name isEqualToString:@"width"] || [name isEqualToString:@"height"];
}

// An atom, plus any trailing `.xyzw`/`.rgba` component swizzles (GLSL style, so
// `value.x` reads a single component and `vec2(value.x, value.y)` rebuilds
// one) or rect member accessors (`.min`/`.max` -> vec2 corner,
// `.width`/`.height` -> scalar side).
static KKExprNode *KKExprParsePostfix(KKExprParser *p) {
  KKExprNode *node = KKExprParseAtom(p);
  if (p->error)
    return nil;
  while (KKExprPeek(p) == '.') {
    // `.` is a member/swizzle only when a letter follows (not `.5` etc).
    char after = (p->pos + 1 < p->len) ? p->s[p->pos + 1] : '\0';
    BOOL alpha =
        (after >= 'a' && after <= 'z') || (after >= 'A' && after <= 'Z');
    if (!alpha && KKExprSwizzleIndex(after) < 0)
      break;
    p->pos++; // consume '.'
    NSString *sw = KKExprReadIdent(p);
    if (KKExprIsRectMember(sw)) {
      KKExprNode *m = [KKExprNode new];
      m->kind = KKNodeMember;
      m->name = sw;
      m->a = node;
      node = m;
      continue;
    }
    if (sw.length < 1 || sw.length > 4) {
      KKExprFail(p, @"swizzle must be 1-4 of x/y/z/w (or r/g/b/a)");
      return nil;
    }
    for (NSUInteger i = 0; i < sw.length; i++)
      if (KKExprSwizzleIndex((char)[sw characterAtIndex:i]) < 0) {
        KKExprFail(p, [NSString stringWithFormat:@"bad swizzle '.%@'", sw]);
        return nil;
      }
    KKExprNode *s = [KKExprNode new];
    s->kind = KKNodeSwizzle;
    s->name = sw;
    s->a = node;
    node = s;
  }
  return node;
}

static KKExprNode *KKExprParseUnary(KKExprParser *p) {
  char c = KKExprPeek(p);
  if (c == '-' || c == '!') {
    p->pos++;
    KKExprNode *child = KKExprParseUnary(p);
    if (p->error)
      return nil;
    KKExprNode *n = [KKExprNode new];
    n->kind = KKNodeUnary;
    n->op = c;
    n->a = child;
    return n;
  }
  if (c == '+') { // unary plus - no-op
    p->pos++;
    return KKExprParseUnary(p);
  }
  return KKExprParsePostfix(p);
}

// Reads the operator at the cursor and returns its code + binding precedence
// (0 = not a binary operator). Does not consume.
static int KKExprPeekBinOp(KKExprParser *p, int *outPrec) {
  KKExprSkipSpace(p);
  if (p->pos >= p->len) {
    *outPrec = 0;
    return 0;
  }
  char c = p->s[p->pos];
  char d = (p->pos + 1 < p->len) ? p->s[p->pos + 1] : '\0';
  switch (c) {
  case '|':
    if (d == '|') {
      *outPrec = 1;
      return KKOpOR;
    }
    break;
  case '&':
    if (d == '&') {
      *outPrec = 2;
      return KKOpAND;
    }
    break;
  case '=':
    if (d == '=') {
      *outPrec = 3;
      return KKOpEQ;
    }
    break;
  case '!':
    if (d == '=') {
      *outPrec = 3;
      return KKOpNE;
    }
    break;
  case '<':
    if (d == '=') {
      *outPrec = 4;
      return KKOpLE;
    }
    *outPrec = 4;
    return '<';
  case '>':
    if (d == '=') {
      *outPrec = 4;
      return KKOpGE;
    }
    *outPrec = 4;
    return '>';
  case '+':
  case '-':
    *outPrec = 5;
    return c;
  case '*':
  case '/':
  case '%':
    *outPrec = 6;
    return c;
  }
  *outPrec = 0;
  return 0;
}

static void KKExprConsumeOp(KKExprParser *p, int op) {
  // advance past the operator we already peeked
  if (op == KKOpOR || op == KKOpAND || op == KKOpEQ || op == KKOpNE ||
      op == KKOpLE || op == KKOpGE)
    p->pos += 2;
  else
    p->pos += 1;
}

static KKExprNode *KKExprParseBinary(KKExprParser *p, int minPrec) {
  KKExprNode *left = KKExprParseUnary(p);
  if (p->error)
    return nil;
  while (1) {
    int prec = 0;
    int op = KKExprPeekBinOp(p, &prec);
    if (op == 0 || prec < minPrec)
      break;
    KKExprConsumeOp(p, op);
    KKExprNode *right = KKExprParseBinary(p, prec + 1); // left-assoc
    if (p->error)
      return nil;
    KKExprNode *n = [KKExprNode new];
    n->kind = KKNodeBinary;
    n->op = op;
    n->a = left;
    n->b = right;
    left = n;
  }
  return left;
}

static KKExprNode *KKExprParseExpr(KKExprParser *p) {
  KKExprNode *cond = KKExprParseBinary(p, 1);
  if (p->error)
    return nil;
  if (KKExprPeek(p) == '?') {
    p->pos++;
    KKExprNode *a = KKExprParseExpr(p);
    if (p->error)
      return nil;
    if (KKExprPeek(p) != ':') {
      KKExprFail(p, @"expected ':' in ternary");
      return nil;
    }
    p->pos++;
    KKExprNode *b = KKExprParseExpr(p);
    if (p->error)
      return nil;
    KKExprNode *n = [KKExprNode new];
    n->kind = KKNodeTernary;
    n->a = cond;
    n->b = a;
    n->c = b;
    return n;
  }
  return cond;
}

static BOOL KKExprIsIdChar(unichar c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') || c == '_';
}

@implementation KKLinkExpr (Parse)

+ (instancetype)compile:(NSString *)source error:(NSString **)error {
  return [self compile:source allowedVars:nil error:error];
}

+ (instancetype)compile:(NSString *)source
            allowedVars:(NSSet<NSString *> *)allowedVars
                  error:(NSString **)error {
  NSString *src = source ?: @"";
  NSString *trimmed = [src
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0)
    trimmed = @"value"; // empty == passthrough

  NSData *utf8 = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
  KKExprParser p = {0};
  p.s = (const char *)utf8.bytes;
  p.len = (long)utf8.length;
  p.pos = 0;
  NSMutableSet<NSString *> *refs = [NSMutableSet set];
  p.refs = refs;
  p.allowedVars = allowedVars;

  KKExprNode *root = KKExprParseExpr(&p);
  if (!p.error) {
    KKExprSkipSpace(&p);
    if (p.pos != p.len)
      KKExprFail(&p, @"trailing characters");
  }
  if (p.error || !root) {
    if (error)
      *error = p.errMsg ?: @"parse error";
    return nil;
  }
  KKLinkExpr *e = [[KKLinkExpr alloc] init];
  e->_root = root;
  e->_refs = [refs allObjects];
  return e;
}

+ (NSRange)errorCharRangeForSource:(NSString *)source
                           message:(NSString *_Nullable *_Nullable)outMessage {
  if (outMessage)
    *outMessage = nil;
  NSString *src = source ?: @"";
  NSString *trimmed = [src
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0)
    return NSMakeRange(NSNotFound, 0); // empty == valid passthrough

  NSData *utf8 = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
  KKExprParser p = {0};
  p.s = (const char *)utf8.bytes;
  p.len = (long)utf8.length;
  NSMutableSet<NSString *> *refs = [NSMutableSet set];
  p.refs = refs;
  KKExprNode *root = KKExprParseExpr(&p);
  if (!p.error) {
    KKExprSkipSpace(&p);
    if (p.pos != p.len)
      KKExprFail(&p, @"trailing characters");
  }
  if (!p.error && root)
    return NSMakeRange(NSNotFound, 0); // valid

  // Byte offset (into the trimmed UTF-8) -> character index into `trimmed`,
  // then shift by the leading whitespace we trimmed so the range indexes
  // `source`.
  long bpos = p.error ? p.errPos : p.len;
  bpos = MAX(0l, MIN(bpos, p.len));
  NSUInteger ci =
      [[[NSString alloc] initWithBytes:utf8.bytes
                                length:(NSUInteger)bpos
                              encoding:NSUTF8StringEncoding] length];
  NSUInteger lead = 0;
  NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  while (lead < src.length && [ws characterIsMember:[src
                                                        characterAtIndex:lead]])
    lead++;
  NSUInteger idx = lead + ci;

  // Expand to the identifier touching idx (unknown name / trailing token), else
  // underline the single offending character.
  NSUInteger start = MIN(idx, src.length), end = start;
  while (start > 0 && KKExprIsIdChar([src characterAtIndex:start - 1]))
    start--;
  while (end < src.length && KKExprIsIdChar([src characterAtIndex:end]))
    end++;
  NSRange bad;
  if (end > start)
    bad = NSMakeRange(start, end - start);
  else if (idx < src.length)
    bad = NSMakeRange(idx, 1);
  else if (src.length > 0)
    bad = NSMakeRange(src.length - 1, 1);
  else
    return NSMakeRange(NSNotFound, 0);

  if (outMessage) {
    NSString *msg = p.errMsg ?: @"parse error";
    // "trailing characters" is opaque; name the token the user actually sees.
    if ([msg isEqualToString:@"trailing characters"])
      msg = [NSString
          stringWithFormat:@"unexpected '%@'", [src substringWithRange:bad]];
    *outMessage = msg;
  }
  return bad;
}

@end
