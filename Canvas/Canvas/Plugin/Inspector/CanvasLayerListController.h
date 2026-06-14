/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the chrome-less Layers panel that appears beside a value/constants
/// editing popover. Observes the kit's static-values popover open/close
/// notifications (scoped to one lanes view) and shows the panel to the LEFT of
/// the popover as a child window, registered keep-alive so clicking it doesn't
/// dismiss the popover. Increment 1: placeholder content (positioning only).
@interface CanvasLayerListController : NSObject
- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
