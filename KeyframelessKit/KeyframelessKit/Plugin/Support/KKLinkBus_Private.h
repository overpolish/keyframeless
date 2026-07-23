/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Internal surface shared between the KKLinkBus translation units: the
// KKLinkedCurve backing that the storage core (KKLinkBus.m) writes when parsing
// a published curve, and the resolver (KKLinkBus+Resolve.m) reads when walking
// an expression. Not a public header - a subscriber only sees the sampled
// -valuesAtTimelineSeconds:outOfRange: on KKLinkBus.h.

#pragma once

#import "KKLinkBus.h"
#import "KKTimingStage.h" // KKLane

NS_ASSUME_NONNULL_BEGIN

@interface KKLinkedCurve ()
@property(nonatomic) KKLane *lane;
@property(nonatomic) double timelineStart;
@property(nonatomic) double timelineEnd;
@property(nonatomic, copy, nullable) NSString *unit;
@end

NS_ASSUME_NONNULL_END
