/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Boolean path operations (union / subtract / intersect / xor) via CoreGraphics
// even-odd fill flattening. Outline + preview live in sibling files.

#import "KKPathBoolean.h"

#import "KKCGPathBridge.h"
#import <CoreGraphics/CoreGraphics.h>


KKBezierPath *KKPathBooleanApply(NSArray<KKBezierPath *> *paths,
                                 KKBooleanOp op) {
  if (paths.count < 2)
    return nil;

  CGPathRef accumulator = CGPathCreateFromKKBezierPath(paths[0]);

  for (NSUInteger i = 1; i < paths.count; i++) {
    CGPathRef operand = CGPathCreateFromKKBezierPath(paths[i]);
    CGPathRef result = NULL;

    switch (op) {
    case KKBooleanOpUnion:
      result = CGPathCreateCopyByUnioningPath(accumulator, operand, true);
      break;
    case KKBooleanOpSubtract:
      result = CGPathCreateCopyBySubtractingPath(accumulator, operand, true);
      break;
    case KKBooleanOpIntersect:
      result = CGPathCreateCopyByIntersectingPath(accumulator, operand, true);
      break;
    case KKBooleanOpXOR:
      result = CGPathCreateCopyBySymmetricDifferenceOfPath(accumulator, operand,
                                                           true);
      break;
    }

    CGPathRelease(operand);
    CGPathRelease(accumulator);

    if (!result)
      return nil;
    accumulator = result;
  }

  KKBezierPath *output = KKBezierPathFromCGPath(accumulator);
  CGPathRelease(accumulator);

  if (output.count == 0)
    return nil;

  KKPathCopyStyleProperties(output, paths[0]);
  KKPathCopyPlacementProperties(output, paths[0]); // stay in the base operand's group
  output.name = paths[0].name;

  return output;
}
