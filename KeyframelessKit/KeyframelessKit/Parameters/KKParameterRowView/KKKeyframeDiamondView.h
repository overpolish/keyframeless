/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

/// Draws a diamond-shaped keyframe indicator.
/// Shows an outlined diamond with a + when no keyframe exists at the current
/// time, and a filled diamond with a − when one does.
@interface KKKeyframeDiamondView : NSView
@property(nonatomic) BOOL keyframeExists;
@end
