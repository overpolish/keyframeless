/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "../Math/KKEasing.h"
#import "KKTimingSlot.h"
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKTimingGraphSection) {
  KKTimingGraphSectionIn = 0,
  KKTimingGraphSectionHold = 1,
  KKTimingGraphSectionOut = 2,
};

@interface KKTimingGraphView : NSView

@property(nonatomic) BOOL inEnabled;
@property(nonatomic) BOOL outEnabled;
@property(nonatomic) double inDuration;
@property(nonatomic) double outDuration;
@property(nonatomic) KKEasingCurve inCurve;
@property(nonatomic) KKEasingCurve outCurve;
@property(nonatomic) KKHoldEffect holdEffect;
@property(nonatomic) double inIntensity;
@property(nonatomic) double outIntensity;
@property(nonatomic) double holdIntensity;
@property(nonatomic) double inFrequency;
@property(nonatomic) double outFrequency;
@property(nonatomic) double holdFrequency;
@property(nonatomic) int holdSeed;

@property(nonatomic) KKTimingGraphSection selectedSection;
@property(nonatomic, copy, nullable) void (^onSectionSelected)
    (KKTimingGraphSection section);
@property(nonatomic, copy, nullable) void (^onInToggled)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onOutToggled)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onInCurveChanged)
    (KKEasingCurve curve);
@property(nonatomic, copy, nullable) void (^onOutCurveChanged)
    (KKEasingCurve curve);
@property(nonatomic, copy, nullable) void (^onHoldEffectChanged)
    (KKHoldEffect effect);
@property(nonatomic, copy, nullable) void (^onInIntensityChanged)
    (double intensity);
@property(nonatomic, copy, nullable) void (^onOutIntensityChanged)
    (double intensity);
@property(nonatomic, copy, nullable) void (^onHoldIntensityChanged)
    (double intensity);
@property(nonatomic, copy, nullable) void (^onInFrequencyChanged)
    (double frequency);
@property(nonatomic, copy, nullable) void (^onOutFrequencyChanged)
    (double frequency);
@property(nonatomic, copy, nullable) void (^onHoldFrequencyChanged)
    (double frequency);
@property(nonatomic, copy, nullable) void (^onHoldSeedChanged)(int seed);
@property(nonatomic, copy, nullable) void (^onInDurationChanged)
    (double duration);
@property(nonatomic, copy, nullable) void (^onOutDurationChanged)
    (double duration);

@property(nonatomic, copy, nullable) NSArray<KKTimingSlot *> *globalSlots;
@property(nonatomic, copy, nullable) NSArray<KKTimingSlot *> *inSectionSlots;
@property(nonatomic, copy, nullable) NSArray<KKTimingSlot *> *holdSectionSlots;
@property(nonatomic, copy, nullable) NSArray<KKTimingSlot *> *outSectionSlots;
@property(nonatomic, strong, nullable) NSView *holdPropertyView;
@property(nonatomic, assign) CGFloat holdPropertyViewHeight;
@property(nonatomic, copy, nullable) void (^holdPropertyApplyState)
    (id paramAPI, CMTime time);

@end

NS_ASSUME_NONNULL_END
