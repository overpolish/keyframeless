/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

#import <KeyframelessKit/KKMotionBlur.h>

NS_ASSUME_NONNULL_BEGIN

// Motion-blur settings popover content: a "Motion Blur" header, then Shutter
// (degrees, 0–360) and Samples (count, 2–128), each a slider (accent track,
// like Radius) + a value field, then a "When" dropdown picking the fire mode.
// Real units so the numbers are meaningful - 180° is the natural shutter, and
// the sample count is explicit (a percentage just invites people to crank it to
// the max).
@interface _KKMotionBlurSettingsView : NSView <NSTextFieldDelegate>
@property(nonatomic, copy, nullable) void (^onChanged)
    (double shutterAngle, NSInteger samples, KKMotionBlurMode mode);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
- (instancetype)initWithShutterAngle:(double)shutterAngle
                             samples:(NSInteger)samples
                                mode:(KKMotionBlurMode)mode;
- (void)applyShutterAngle:(double)shutterAngle
                  samples:(NSInteger)samples
                     mode:(KKMotionBlurMode)mode;
@end

NS_ASSUME_NONNULL_END
