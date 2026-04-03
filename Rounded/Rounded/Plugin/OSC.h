/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

@interface RoundedOSC : KKPointOSC
@property(nonatomic, strong) KKPointOSC *cropTopLeftOSC;
@property(nonatomic) BOOL cropTopLeftHovered;
@property(nonatomic) BOOL cropTopLeftDragging;
@property(nonatomic, strong) KKRectBorderOSC *cropBorderOSC;
@property(nonatomic, strong) KKOSCLabel *cropSizeLabel;
@end
