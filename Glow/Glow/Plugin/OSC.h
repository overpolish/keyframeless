/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

@interface GlowOSC : KKArcOSC

@property(nonatomic, readonly) KKRingOSC *radiusRing;

@end
