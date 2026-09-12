/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Inspector value field. Focus is acquired by an explicit click, and a
/// horizontal drag scrubs the numeric value.
@interface ICValueTextField : NSTextField
@property(nonatomic, readonly) BOOL icEditing;
@property(nonatomic, readonly) BOOL icScrubbing;
@property(nonatomic) double scrubStep;
@property(nonatomic) BOOL scrubDisabled;
@property(nonatomic, copy, nullable) void (^onScrubBegin)(void);
@property(nonatomic, copy, nullable) void (^onScrubEnd)(void);

+ (instancetype)valueField;
@end

/// Converts accumulated horizontal travel into whole scrub steps. Remaining
/// travel is retained by the caller; the field uses four points per step.
FOUNDATION_EXPORT NSInteger ICScrubWholeStepsForTravel(CGFloat travel);

FOUNDATION_EXPORT BOOL ICValueFieldHandleReturnCommand(
    NSWindow *_Nullable window, SEL commandSelector);
FOUNDATION_EXPORT BOOL ICValueFieldHandleTabCommand(NSTextField *field,
                                                    SEL commandSelector);

NS_ASSUME_NONNULL_END
