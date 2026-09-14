/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

#import <KeyframelessKit/KKMotionBlur.h>

NS_ASSUME_NONNULL_BEGIN

// Motion-blur settings popover content: a "Motion Blur" header, a Quality pill
// (Fast / Accurate - shown only when the host opts into Fast via
// `supportsFast`), a Shutter slider (degrees, 0–360), and - for Accurate only -
// a Samples slider (count, 2–128). Real units so the numbers are meaningful;
// 180° is the natural shutter. The Samples row is REMOVED (not greyed) in Fast,
// so the popover resizes via `onLayoutChanged`.
@interface _KKMotionBlurSettingsView : NSView <NSTextFieldDelegate>
@property(nonatomic, copy, nullable) void (^onChanged)
    (double shutterAngle, NSInteger samples, KKMotionBlurTechnique technique);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
/// Fired when the content height changes (Samples row added/removed) so the host
/// popover can resize to `self.frame.size`.
@property(nonatomic, copy, nullable) void (^onLayoutChanged)(void);
/// Whether the host plugin supports the Fast (reconstruction) technique. NO
/// hides the Quality pill and forces Accurate (the universal accumulate path).
- (instancetype)initWithShutterAngle:(double)shutterAngle
                             samples:(NSInteger)samples
                           technique:(KKMotionBlurTechnique)technique
                         supportsFast:(BOOL)supportsFast
                      defaultSamples:(NSInteger)defaultSamples;
- (void)applyShutterAngle:(double)shutterAngle
                  samples:(NSInteger)samples
                technique:(KKMotionBlurTechnique)technique;
@end

NS_ASSUME_NONNULL_END
