/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Parses an SVG string and returns an array of KKBezierPath objects.
/// Coordinates are normalized to 0-1 object space with Y=0 at bottom.
/// Supports: <path>, <rect>, <circle>, <ellipse>, <line>, <polygon>,
/// <polyline>. Extracts fill/stroke colors. Unsupported elements are skipped.
@interface KKSVGParser : NSObject

/// Parse SVG content and return paths. canvasWidth/canvasHeight are needed
/// to compensate for aspect ratio (object space 0-1 gets stretched to canvas
/// dimensions). If the SVG contains multiple visible elements, the caller
/// should wrap them in a group.
+ (NSArray<KKBezierPath *> *)pathsFromSVGString:(NSString *)svgString
                                    canvasWidth:(float)canvasWidth
                                   canvasHeight:(float)canvasHeight;

@end

NS_ASSUME_NONNULL_END
