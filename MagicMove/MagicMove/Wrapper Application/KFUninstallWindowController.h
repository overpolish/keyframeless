/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The window the wrapper application shows when it is launched: what is
// installed, where the hosts find it, and a way to remove it again.
@interface KFUninstallWindowController : NSWindowController

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
