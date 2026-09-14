/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The CoreGraphics <-> KKBezierPath bridge shared by the path operations split
// out of KKPathBoolean.m: outline tessellation (KKPathOutline.m), boolean ops
// (KKPathBoolean.m), and the preview overlay (KKPathBooleanPreview.m). Internal
// to the geometry layer - not a public header.

#pragma once

#import "KKBezierPath.h"
#import <CoreGraphics/CoreGraphics.h>

// Build a CGPath from a KKBezierPath's points (respects the closed flag and
// per-contour subpaths). Caller owns the returned path.
CGMutablePathRef CGPathCreateFromKKBezierPath(KKBezierPath *path);

// Rebuild a KKBezierPath (linear points) from a flattened CGPath.
KKBezierPath *KKBezierPathFromCGPath(CGPathRef cgPath);

// Copy layer placement (transform / group / layer identity) from src to dst.
void KKPathCopyPlacementProperties(KKBezierPath *dst, KKBezierPath *src);

// Copy stroke / fill / style properties from src to dst.
void KKPathCopyStyleProperties(KKBezierPath *dst, KKBezierPath *src);
