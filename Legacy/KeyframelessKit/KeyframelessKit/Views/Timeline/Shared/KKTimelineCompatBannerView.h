/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Frosted overlay shown when the user tries to switch Advanced → Basic
// while the timeline has Advanced-only structure. Confirms "Switch anyway"
// (reseeds incompatible lanes to flat hold) or Cancel.
@interface _KKCompatBannerView : NSView
@property(nonatomic, copy, nullable) void (^onCancel)(void);
@property(nonatomic, copy, nullable) void (^onConfirm)(void);
@end

NS_ASSUME_NONNULL_END
