/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A vertically-scrolling content area sized to fit a remote-window host.
/// The padding lives on the scroll view's outer constraints (so margins
/// stay visible on all sides) and the inner clip view is flipped so the
/// document anchors at the top instead of the bottom. The document view
/// is given a width equal to the visible scroll width, with intrinsic
/// height - content grows downward and scrolls when it exceeds the
/// container height.
///
/// Usage from a remote-window reply: build your content as a single
/// NSView (e.g. an NSStackView), pass it as `documentView`, then pin
/// the resulting `KKPaddedScrollView` to your host's edges.
@interface KKPaddedScrollView : NSView

- (instancetype)initWithDocumentView:(NSView *)documentView
                             padding:(CGFloat)padding;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
