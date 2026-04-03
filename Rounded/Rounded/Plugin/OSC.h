/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

#define kCropPointCount 8

@interface RoundedOSC : KKPointOSC
@property(nonatomic, strong) NSArray<KKPointOSC *> *cropPointOSCs;
@property(nonatomic) NSInteger cropHoveredIndex;
@property(nonatomic) NSInteger cropDraggingIndex;
@property(nonatomic, strong) KKRectBorderOSC *cropBorderOSC;
@property(nonatomic, strong) KKOSCLabel *cropSizeLabel;
@end
