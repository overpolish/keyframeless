/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

@protocol PROAPIAccessing;

@interface KKNativeStyleView : NSView

@property(nonatomic, strong) id<PROAPIAccessing> apiManager;
@property(nonatomic, assign) UInt32 parameterId;

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId;

@end
