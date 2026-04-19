/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKBezierPath.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKBooleanOp) {
  KKBooleanOpUnion,
  KKBooleanOpSubtract,
  KKBooleanOpIntersect,
  KKBooleanOpXOR,
};

/// Perform a boolean operation on two or more paths.
/// Returns a new path with the result, or nil on failure.
/// The result inherits style properties from the first path.
KKBezierPath *_Nullable KKPathBooleanApply(NSArray<KKBezierPath *> *paths,
                                           KKBooleanOp op);

NS_ASSUME_NONNULL_END
