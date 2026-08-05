/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Internal surface shared between KKLinkExpr's split translation units:
// KKLinkExpr+Parse.m (source text -> node tree), KKLinkExpr+Format.m (node tree
// -> canonical source), and KKLinkExpr.m (node tree -> value). Not a public
// header - the AST is an implementation detail of the evaluator.

#pragma once

#import "KKLinkExpr.h"

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
  KKNodeMember,  // rect accessor on the child: `.min .max .width .height`
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

// x/r -> 0, y/g -> 1, z/b -> 2, w/a -> 3; -1 if not a swizzle letter. Shared by
// the parser (postfix `.xyzw`) and the evaluator (KKNodeSwizzle).
static inline int KKExprSwizzleIndex(char c) {
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

@interface KKLinkExpr () {
@package
  KKExprNode *_root;
  NSArray<NSString *> *_refs;
}
@end
