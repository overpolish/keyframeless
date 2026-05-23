/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds the generic OSC portion of a joyride — one combined press→drag→
/// release step plus a final "available whenever selected" tip — and owns the
/// step/position observers that drive the controller off the bridge's
/// notifications. Plugin- and OSC-shape-agnostic: the bridge supplies the
/// affine, the strategy supplies the value mapping.
///
/// Splitting press and drag into two steps forced an extra click (advancing on
/// mousedown rebuilt the panel + monitors, consuming the press). The joyride
/// installs the drag monitor right after mousedown, so one step handles the
/// whole gesture; only mouseUp advances. The press swaps the message/counter
/// in place so it still reads as two steps.
@interface KKJoyrideOSCSegment : NSObject

- (instancetype)initWithBridge:(KKOSCGuideBridge *)bridge
                      strategy:(KKOSCGuideStrategy *)strategy
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Builds the steps and installs the observers that advance/refresh `guide`.
/// displayBase offsets the visible step counter (so numbers continue from an
/// inspector portion); displayTotal sets "of N" (0 = auto). firstStepOnEnter
/// runs when the combined step becomes active (e.g. a crossover warm-up).
/// Call -teardown from the guide's onComplete.
- (NSArray<KKJoyrideStep *> *)stepsForGuide:(KKJoyrideController *)guide
                                displayBase:(NSInteger)displayBase
                               displayTotal:(NSInteger)displayTotal
                           firstStepOnEnter:
                               (nullable void (^)(void))firstStepOnEnter;

/// Removes the notification observers. Idempotent.
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
