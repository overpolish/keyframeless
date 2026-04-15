/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

/// Create a jittered copy of the path for sketch-style rendering.
/// The result is a new path with randomized control points.
/// Pass roughness (0-3), bowing (0-3), a fixed seed, and the canvas
/// dimensions so jitter scales correctly with stroke width.
KKBezierPath *KKSketchPath(KKBezierPath *path, float roughness, float bowing, uint32_t seed, uint8_t strokes,
                           float canvasWidth, float canvasHeight);
