/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "../Math/KKEasing.h"
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKTimingGraphSection) {
  KKTimingGraphSectionIn = 0,
  KKTimingGraphSectionMid = 1,
  KKTimingGraphSectionOut = 2,
};

@interface KKTimingGraphView : NSView

@property(nonatomic) BOOL inEnabled;
@property(nonatomic) BOOL outEnabled;
@property(nonatomic) KKEasingCurve inCurve;
@property(nonatomic) KKEasingCurve outCurve;

@property(nonatomic) KKTimingGraphSection selectedSection;
@property(nonatomic, copy, nullable) void (^onSectionSelected)
    (KKTimingGraphSection section);
@property(nonatomic, copy, nullable) void (^onInToggled)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onOutToggled)(BOOL enabled);

@end

NS_ASSUME_NONNULL_END
