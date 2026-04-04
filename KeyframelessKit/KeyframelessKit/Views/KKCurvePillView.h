/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef CGFloat (^KKCurvePillValueBlock)(NSInteger pillIndex, CGFloat t);

@interface KKCurvePillView : NSView

@property(nonatomic) NSInteger pillCount;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

/// Block that evaluates the curve for a given pill index and normalized t.
/// Used to render the mini curve icon in each pill.
@property(nonatomic, copy, nullable) KKCurvePillValueBlock valueBlock;

- (void)redraw;

@end

NS_ASSUME_NONNULL_END
