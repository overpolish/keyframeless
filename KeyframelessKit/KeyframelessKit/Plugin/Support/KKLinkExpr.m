/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLinkExpr.h"

#import "KKEasing.h" // easeIn/easeOut/... share the timeline's KKApplyEasing
#import <math.h>

typedef NS_ENUM(int, KKExprKind) {
  KKNodeNum,
  KKNodeValue,
  KKNodeTime,
  KKNodeProgress, // `progress`: 0..1 across the clip
  KKNodeClipTime, // `ct`: seconds since the clip started
  KKNodeRef,
  KKNodeUnary,
  KKNodeBinary,
  KKNodeTernary,
  KKNodeCall,
  KKNodeSwizzle, // `.xyzw` / `.rgba` component select on the child
  KKNodeVar,     // a caller-supplied named variable (OSC: mouse/pos/tr/…)
};

// Multi-char operator codes (single-char ops use their ASCII value).
enum {
  KKOpLE = 256,
  KKOpGE,
  KKOpEQ,
  KKOpNE,
  KKOpAND,
  KKOpOR,
};

@interface KKExprNode : NSObject {
@public
  KKExprKind kind;
  double num;                  // KKNodeNum
  NSString *name;              // KKNodeRef (ref name) / KKNodeCall (fn name)
  int op;                      // KKNodeUnary / KKNodeBinary operator code
  KKExprNode *a, *b, *c;       // children (ternary uses all three)
  NSArray<KKExprNode *> *args; // KKNodeCall
}
@end
@implementation KKExprNode
@end

// ---- parser state ---------------------------------------------------------

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

// x/r -> 0, y/g -> 1, z/b -> 2, w/a -> 3; -1 if not a swizzle letter.
static int KKExprSwizzleIndex(char c) {
  switch (c) {
  case 'x':
  case 'r':
    return 0;
  case 'y':
  case 'g':
    return 1;
  case 'z':
  case 'b':
    return 2;
  case 'w':
  case 'a':
    return 3;
  }
  return -1;
}

// An atom, plus any trailing `.xyzw`/`.rgba` component swizzles (GLSL style, so
// `value.x` reads a single component and `vec2(value.x, value.y)` rebuilds
// one).
static KKExprNode *KKExprParsePostfix(KKExprParser *p) {
  KKExprNode *node = KKExprParseAtom(p);
  if (p->error)
    return nil;
  while (KKExprPeek(p) == '.') {
    // `.` is a swizzle only when a component letter follows (not `.5` etc).
    char after = (p->pos + 1 < p->len) ? p->s[p->pos + 1] : '\0';
    if (KKExprSwizzleIndex(after) < 0)
      break;
    p->pos++; // consume '.'
    NSString *sw = KKExprReadIdent(p);
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

// ---- evaluation -----------------------------------------------------------

static double KKExprComp(KKExprVal x, int i) {
  return x.v[x.n == 1 ? 0 : (i < x.n ? i : x.n - 1)];
}

static KKExprVal KKExprBroadcast2(KKExprVal a, KKExprVal b,
                                  double (^f)(double, double)) {
  KKExprVal r;
  r.n = a.n > b.n ? a.n : b.n;
  if (r.n < 1)
    r.n = 1;
  if (r.n > 4)
    r.n = 4;
  for (int i = 0; i < r.n; i++)
    r.v[i] = f(KKExprComp(a, i), KKExprComp(b, i));
  return r;
}

static KKExprVal KKExprMap1(KKExprVal a, double (^f)(double)) {
  KKExprVal r;
  r.n = a.n;
  for (int i = 0; i < a.n; i++)
    r.v[i] = f(a.v[i]);
  return r;
}

static double KKClampD(double x, double lo, double hi) {
  return x < lo ? lo : (x > hi ? hi : x);
}

@implementation KKLinkExpr {
  KKExprNode *_root;
  NSArray<NSString *> *_refs;
  // Per-evaluation context, constant across one -evalWithValue... pass (nested
  // `${ref}` resolution evaluates a DIFFERENT KKLinkExpr instance, so these are
  // never re-entered on the same instance). Held as ivars so the recursive node
  // walk stays a plain `-eval:` without threading every scalar through it.
  KKExprVal _cValue;
  double _cT, _cProgress, _cClipTime;
  KKExprVal (^_cResolveRef)(NSString *);
  KKExprVal (^_cVars)(NSString *); // OSC bare-variable resolver
}

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

static BOOL KKExprIsIdChar(unichar c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') || c == '_';
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

- (NSArray<NSString *> *)references {
  return _refs;
}

// ---- pretty-printer (Format) ----------------------------------------------

static NSString *KKExprFmtNum(double x) {
  // Fold the folded-at-parse constants back to their friendly names.
  if (fabs(x - M_PI) < 1e-12)
    return @"pi";
  if (fabs(x - 2.0 * M_PI) < 1e-12)
    return @"tau";
  if (fabs(x - M_E) < 1e-12)
    return @"e";
  // %g trims trailing zeros; enough precision to round-trip typical values.
  return [NSString stringWithFormat:@"%.12g", x];
}

static NSString *KKExprOpStr(int op) {
  switch (op) {
  case KKOpLE:
    return @"<=";
  case KKOpGE:
    return @">=";
  case KKOpEQ:
    return @"==";
  case KKOpNE:
    return @"!=";
  case KKOpAND:
    return @"&&";
  case KKOpOR:
    return @"||";
  default:
    return [NSString stringWithFormat:@"%c", (char)op];
  }
}

static int KKExprBinPrec(int op) {
  switch (op) {
  case KKOpOR:
    return 1;
  case KKOpAND:
    return 2;
  case KKOpEQ:
  case KKOpNE:
    return 3;
  case '<':
  case '>':
  case KKOpLE:
  case KKOpGE:
    return 4;
  case '+':
  case '-':
    return 5;
  case '*':
  case '/':
  case '%':
    return 6;
  default:
    return 5;
  }
}

// Binding tightness of a node, so a parent can decide when a child needs parens
// (ternary loosest .. atom tightest). Mirrors the parser's precedence ladder.
static int KKExprNodePrec(KKExprNode *n) {
  switch (n->kind) {
  case KKNodeTernary:
    return 0;
  case KKNodeBinary:
    return KKExprBinPrec(n->op);
  case KKNodeUnary:
    return 7;
  default:
    return 8; // num / value / t / ref / call
  }
}

static NSString *KKExprEmit(KKExprNode *n);

// Emit `child`, wrapping in parens when it binds looser than `threshold`.
static NSString *KKExprWrap(KKExprNode *child, int threshold) {
  NSString *s = KKExprEmit(child);
  return KKExprNodePrec(child) < threshold
             ? [NSString stringWithFormat:@"(%@)", s]
             : s;
}

static NSString *KKExprEmit(KKExprNode *n) {
  switch (n->kind) {
  case KKNodeNum:
    return KKExprFmtNum(n->num);
  case KKNodeValue:
    return @"value";
  case KKNodeTime:
    return @"t";
  case KKNodeProgress:
    return @"progress";
  case KKNodeClipTime:
    return @"ct";
  case KKNodeRef:
    return [NSString stringWithFormat:@"${%@}", n->name];
  case KKNodeVar:
    return n->name;
  case KKNodeSwizzle:
    return [NSString stringWithFormat:@"%@.%@", KKExprWrap(n->a, 8), n->name];
  case KKNodeUnary:
    return
        [NSString stringWithFormat:@"%c%@", (char)n->op, KKExprWrap(n->a, 7)];
  case KKNodeBinary: {
    int p = KKExprBinPrec(n->op);
    // Left keeps equal precedence unparenthesized (left-assoc); the right side
    // needs strictly tighter to preserve `a - (b - c)`.
    return
        [NSString stringWithFormat:@"%@ %@ %@", KKExprWrap(n->a, p),
                                   KKExprOpStr(n->op), KKExprWrap(n->b, p + 1)];
  }
  case KKNodeTernary:
    return [NSString stringWithFormat:@"%@ ? %@ : %@", KKExprWrap(n->a, 1),
                                      KKExprEmit(n->b), KKExprEmit(n->c)];
  case KKNodeCall: {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (KKExprNode *arg in n->args)
      [parts addObject:KKExprEmit(arg)];
    return [NSString stringWithFormat:@"%@(%@)", n->name,
                                      [parts componentsJoinedByString:@", "]];
  }
  }
  return @"";
}

- (NSString *)formattedSource {
  return KKExprEmit(_root);
}

- (KKExprVal)eval:(KKExprNode *)node {
  switch (node->kind) {
  case KKNodeNum:
    return KKExprScalar(node->num);
  case KKNodeValue:
    return _cValue;
  case KKNodeTime:
    return KKExprScalar(_cT);
  case KKNodeProgress:
    return KKExprScalar(_cProgress);
  case KKNodeClipTime:
    return KKExprScalar(_cClipTime);
  case KKNodeRef:
    return _cResolveRef ? _cResolveRef(node->name) : KKExprScalar(0.0);
  case KKNodeVar:
    return _cVars ? _cVars(node->name) : KKExprScalar(0.0);
  case KKNodeSwizzle: {
    KKExprVal cv = [self eval:node->a];
    const char *s = node->name.UTF8String;
    int len = (int)node->name.length;
    KKExprVal r;
    r.n = len < 1 ? 1 : (len > 4 ? 4 : len);
    for (int i = 0; i < r.n; i++) {
      int idx = KKExprSwizzleIndex(s[i]);
      r.v[i] = KKExprComp(cv, idx < 0 ? 0 : idx);
    }
    return r;
  }
  case KKNodeUnary: {
    KKExprVal x = [self eval:node->a];
    if (node->op == '-')
      return KKExprMap1(x, ^(double v) {
        return -v;
      });
    return KKExprMap1(x, ^(double v) {
      return v == 0.0 ? 1.0 : 0.0;
    }); // '!'
  }
  case KKNodeTernary: {
    KKExprVal cond = [self eval:node->a];
    return cond.v[0] != 0.0 ? [self eval:node->b] : [self eval:node->c];
  }
  case KKNodeBinary: {
    KKExprVal a = [self eval:node->a];
    KKExprVal b = [self eval:node->b];
    switch (node->op) {
    case '+':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x + y;
      });
    case '-':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x - y;
      });
    case '*':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x * y;
      });
    case '/':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return y == 0.0 ? 0.0 : x / y;
      });
    case '%':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return y == 0.0 ? 0.0 : fmod(x, y);
      });
    case '<':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x < y ? 1.0 : 0.0;
      });
    case '>':
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x > y ? 1.0 : 0.0;
      });
    case KKOpLE:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x <= y ? 1.0 : 0.0;
      });
    case KKOpGE:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x >= y ? 1.0 : 0.0;
      });
    case KKOpEQ:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x == y ? 1.0 : 0.0;
      });
    case KKOpNE:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return x != y ? 1.0 : 0.0;
      });
    case KKOpAND:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return (x != 0.0 && y != 0.0) ? 1.0 : 0.0;
      });
    case KKOpOR:
      return KKExprBroadcast2(a, b, ^(double x, double y) {
        return (x != 0.0 || y != 0.0) ? 1.0 : 0.0;
      });
    }
    return a;
  }
  case KKNodeCall: {
    NSArray<KKExprNode *> *an = node->args;
    NSUInteger nc = an.count;
    NSString *fn = node->name;
    // Vector constructors: flatten every arg's components in order and take N
    // (GLSL: vec2(x,y), vec4(v2, a, b), vec3(x) -> broadcast). Handled before
    // the 3-arg shortcut below because vec4 takes four args.
    if (fn.length == 4 && [fn hasPrefix:@"vec"]) {
      int N = (int)[fn characterAtIndex:3] - '0';
      if (N >= 2 && N <= 4) {
        double comps[4];
        int k = 0;
        for (KKExprNode *arg in an) {
          KKExprVal av = [self eval:arg];
          for (int i = 0; i < av.n && k < 4; i++)
            comps[k++] = av.v[i];
        }
        KKExprVal r;
        r.n = N;
        for (int i = 0; i < N; i++)
          r.v[i] = (k == 1) ? comps[0] : (i < k ? comps[i] : 0.0);
        return r;
      }
    }
    KKExprVal a0 = nc > 0 ? [self eval:an[0]] : KKExprScalar(0);
    KKExprVal a1 = nc > 1 ? [self eval:an[1]] : KKExprScalar(0);
    KKExprVal a2 = nc > 2 ? [self eval:an[2]] : KKExprScalar(0);
    // Vector reducers (GLSL): length(v), distance(a,b), dot(a,b) -> scalar;
    // normalize(v) -> unit vector. Handle before the per-component maps.
    if ([fn isEqualToString:@"length"] || [fn isEqualToString:@"normalize"]) {
      double s = 0;
      for (int i = 0; i < a0.n; i++)
        s += a0.v[i] * a0.v[i];
      double len = sqrt(s);
      if ([fn isEqualToString:@"length"])
        return KKExprScalar(len);
      KKExprVal r = a0;
      if (len > 1e-12)
        for (int i = 0; i < r.n; i++)
          r.v[i] /= len;
      return r;
    }
    if ([fn isEqualToString:@"distance"]) {
      double s = 0;
      int m = MAX(a0.n, a1.n);
      for (int i = 0; i < m; i++) {
        double d = (i < a0.n ? a0.v[i] : 0) - (i < a1.n ? a1.v[i] : 0);
        s += d * d;
      }
      return KKExprScalar(sqrt(s));
    }
    if ([fn isEqualToString:@"dot"]) {
      double s = 0;
      int m = MIN(a0.n, a1.n);
      for (int i = 0; i < m; i++)
        s += a0.v[i] * a1.v[i];
      return KKExprScalar(s);
    }
    // 1-arg per-component
    if ([fn isEqualToString:@"sin"])
      return KKExprMap1(a0, ^(double x) {
        return sin(x);
      });
    if ([fn isEqualToString:@"cos"])
      return KKExprMap1(a0, ^(double x) {
        return cos(x);
      });
    if ([fn isEqualToString:@"tan"])
      return KKExprMap1(a0, ^(double x) {
        return tan(x);
      });
    if ([fn isEqualToString:@"abs"])
      return KKExprMap1(a0, ^(double x) {
        return fabs(x);
      });
    if ([fn isEqualToString:@"sign"])
      return KKExprMap1(a0, ^(double x) {
        return (double)((x > 0) - (x < 0));
      });
    if ([fn isEqualToString:@"floor"])
      return KKExprMap1(a0, ^(double x) {
        return floor(x);
      });
    if ([fn isEqualToString:@"ceil"])
      return KKExprMap1(a0, ^(double x) {
        return ceil(x);
      });
    if ([fn isEqualToString:@"round"])
      return KKExprMap1(a0, ^(double x) {
        return round(x);
      });
    if ([fn isEqualToString:@"sqrt"])
      return KKExprMap1(a0, ^(double x) {
        return x < 0 ? 0 : sqrt(x);
      });
    if ([fn isEqualToString:@"exp"])
      return KKExprMap1(a0, ^(double x) {
        return exp(x);
      });
    if ([fn isEqualToString:@"log"])
      return KKExprMap1(a0, ^(double x) {
        return x <= 0 ? 0 : log(x);
      });
    if ([fn isEqualToString:@"rad"])
      return KKExprMap1(a0, ^(double x) {
        return x * M_PI / 180.0;
      });
    if ([fn isEqualToString:@"deg"])
      return KKExprMap1(a0, ^(double x) {
        return x * 180.0 / M_PI;
      });
    // 2-arg broadcast
    if ([fn isEqualToString:@"min"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return x < y ? x : y;
      });
    if ([fn isEqualToString:@"max"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return x > y ? x : y;
      });
    if ([fn isEqualToString:@"mod"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return y == 0 ? 0 : fmod(x, y);
      });
    if ([fn isEqualToString:@"pow"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return pow(x, y);
      });
    if ([fn isEqualToString:@"atan2"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return atan2(x, y);
      });
    if ([fn isEqualToString:@"hypot"])
      return KKExprBroadcast2(a0, a1, ^(double x, double y) {
        return hypot(x, y);
      });
    if ([fn isEqualToString:@"step"])
      return KKExprBroadcast2(a0, a1, ^(double edge, double x) {
        return x < edge ? 0.0 : 1.0;
      });
    // 3-arg broadcast
    if ([fn isEqualToString:@"clamp"]) {
      KKExprVal r;
      r.n = a0.n;
      for (int i = 0; i < a0.n; i++)
        r.v[i] = KKClampD(a0.v[i], KKExprComp(a1, i), KKExprComp(a2, i));
      return r;
    }
    if ([fn isEqualToString:@"lerp"] || [fn isEqualToString:@"mix"]) {
      KKExprVal r;
      r.n = a0.n > a1.n ? a0.n : a1.n;
      for (int i = 0; i < r.n; i++) {
        double x = KKExprComp(a0, i), y = KKExprComp(a1, i),
               u = KKExprComp(a2, i);
        r.v[i] = x + (y - x) * u;
      }
      return r;
    }
    if ([fn isEqualToString:@"smoothstep"]) {
      KKExprVal r;
      r.n = a2.n;
      for (int i = 0; i < a2.n; i++) {
        double e0 = KKExprComp(a0, i), e1 = KKExprComp(a1, i), x = a2.v[i];
        double u = e1 == e0 ? 0.0 : KKClampD((x - e0) / (e1 - e0), 0.0, 1.0);
        r.v[i] = u * u * (3.0 - 2.0 * u);
      }
      return r;
    }
    // Time -> repeating 0..1 PHASE helpers, so unbounded `t` can drive the
    // easing/curve functions (which expect a 0..1 progress). `period` seconds
    // (default 1). repeat = sawtooth 0->1 (jumps back); pingpong = triangle
    // 0->1->0 (there and back), one full cycle per period.
    if ([fn isEqualToString:@"repeat"]) {
      double period = nc > 1 ? KKExprComp(a1, 0) : 1.0;
      return KKExprMap1(a0, ^(double x) {
        return period == 0.0 ? 0.0
                             : fmod(fmod(x, period) + period, period) / period;
      });
    }
    if ([fn isEqualToString:@"pingpong"]) {
      double period = nc > 1 ? KKExprComp(a1, 0) : 1.0;
      return KKExprMap1(a0, ^(double x) {
        if (period == 0.0)
          return 0.0;
        double p = fmod(fmod(x, period) + period, period) / period; // 0..1
        return 1.0 - fabs(2.0 * p - 1.0);
      });
    }
    // Keypose easing curves, identical to the timeline sampler (shared
    // KKApplyEasing): a 0..1 factor in -> eased 0..1 out, per component.
    // Optional 2nd arg = intensity (0..1, default 0.5); 3rd = frequency
    // (elastic/bounce only, default 0.5).
    NSInteger ecurve = -1;
    if ([fn isEqualToString:@"easeIn"])
      ecurve = KKEasingCurveEaseIn;
    else if ([fn isEqualToString:@"easeOut"])
      ecurve = KKEasingCurveEaseOut;
    else if ([fn isEqualToString:@"easeInOut"])
      ecurve = KKEasingCurveEaseInOut;
    else if ([fn isEqualToString:@"elastic"])
      ecurve = KKEasingCurveElastic;
    else if ([fn isEqualToString:@"bounce"])
      ecurve = KKEasingCurveBounce;
    if (ecurve >= 0) {
      double intensity = nc > 1 ? KKExprComp(a1, 0) : 0.5;
      double frequency = nc > 2 ? KKExprComp(a2, 0) : 0.5;
      KKEasingCurve c = (KKEasingCurve)ecurve;
      return KKExprMap1(a0, ^(double x) {
        return KKApplyEasing(x, c, intensity, frequency);
      });
    }
    return a0; // unknown function: passthrough first arg
  }
  }
  return KKExprScalar(0.0);
}

- (KKExprVal)evalWithValue:(KKExprVal)value
                         t:(double)t
                  progress:(double)progress
                  clipTime:(double)clipTime
                resolveRef:(KKExprVal (^)(NSString *))resolveRef {
  _cValue = value;
  _cT = t;
  _cProgress = progress;
  _cClipTime = clipTime;
  _cResolveRef = resolveRef;
  _cVars = nil;
  return [self eval:_root];
}

- (KKExprVal)evalWithValue:(KKExprVal)value
                      vars:(KKExprVal (^)(NSString *))vars {
  _cValue = value;
  _cT = 0.0;
  _cProgress = 0.0;
  _cClipTime = 0.0;
  _cResolveRef = nil;
  _cVars = vars;
  return [self eval:_root];
}

@end
