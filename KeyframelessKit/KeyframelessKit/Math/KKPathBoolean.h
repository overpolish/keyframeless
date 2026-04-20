/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKBezierPath.h>

@protocol MTLDevice;
@protocol MTLTexture;

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

/// Convert the stroke of each path into a filled outline path.
/// Returns one outline path per input path, or nil entries on failure.
/// referenceWidth/Height are pixel dimensions used to scale the stroke
/// width into object space (path coords are 0-1 normalised).
NSArray<KKBezierPath *> *_Nullable KKPathStrokeToOutline(
    NSArray<KKBezierPath *> *paths, CGFloat referenceWidth,
    CGFloat referenceHeight);

/// Render a preview overlay texture showing which regions stay (green)
/// and which are removed (red) by a boolean operation.
/// width/height are ioSurface pixel dimensions.
id<MTLTexture> _Nullable KKPathBooleanPreviewTexture(
    NSArray<KKBezierPath *> *selectedPaths, KKBezierPath *_Nullable resultPath,
    CGFloat width, CGFloat height, id<MTLDevice> device);

NS_ASSUME_NONNULL_END
