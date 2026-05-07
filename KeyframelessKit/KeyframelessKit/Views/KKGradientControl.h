/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

@class KKGradientStop;

NS_ASSUME_NONNULL_BEGIN

/// A reusable gradient editor row: gradient bar + favorites/reverse/distribute
/// buttons. Owns its favorites popover. Used by plugins that expose a single
/// gradient parameter, and by Canvas (per-path gradients) where each path
/// instantiates its own control.
@interface KKGradientControl : NSView

@property(nonatomic, copy) NSArray<KKGradientStop *> *stops;

/// Fired whenever the user mutates the gradient (drag, color edit, reverse,
/// distribute, favorite-apply).
@property(nonatomic, copy, nullable) void (^onStopsChanged)
    (NSArray<KKGradientStop *> *newStops);

/// Forwarded from the underlying gradient bar. Lets the consumer bracket
/// the entire stop/midpoint drag in one undo group.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

@end

NS_ASSUME_NONNULL_END
