/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

@protocol PROAPIAccessing;

@interface KKParameterRowView : NSView

@property(nonatomic, strong) id<PROAPIAccessing> apiManager;
@property(nonatomic, assign) UInt32 parameterId;

/// Optional left section view. When nil, rightView fills all available space.
@property(nonatomic, strong, nullable) NSView *leftView;

/// Optional right section view. When nil, leftView fills all available space.
@property(nonatomic, strong, nullable) NSView *rightView;

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId;

@end
