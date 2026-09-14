/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// KKExprNode tree -> canonical source text. The pretty-printer that backs
// -formattedSource: minimal parenthesisation driven by the same precedence
// ladder the parser uses, and folds the parse-time constants (pi/tau/e) back to
// their names.

#import "KKLinkExpr_Private.h"

#import <math.h>

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
  case KKNodeMember:
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

@implementation KKLinkExpr (Format)

- (NSString *)formattedSource {
  return KKExprEmit(_root);
}

@end
