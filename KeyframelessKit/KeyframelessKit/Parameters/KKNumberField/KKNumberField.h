/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class KKLog;
@protocol PROAPIAccessing;

extern const CGFloat kNumberFieldWidth;
extern const CGFloat kNumberFieldHeight;

@interface KKNumberField : NSView <NSTextFieldDelegate>
@property(nonatomic) double minValue;
@property(nonatomic) double maxValue;
@property(nonatomic) BOOL isStepperMode;
@property(nonatomic) CGFloat stepValue;
@property(nonatomic) CGFloat dragScale;
@property(nonatomic) CGFloat shiftStepMultiplier;
@property(nonatomic) CGFloat optionStepMultiplier;
@property(nonatomic) CGFloat numberValue;
@property(nonatomic, strong) KKLog *log;

@property(nonatomic, copy, nullable) NSString *prefix;
@property(nonatomic, copy, nullable) NSString *suffix;

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager;

- (NSRect)textBounds;

@end

NS_ASSUME_NONNULL_END
