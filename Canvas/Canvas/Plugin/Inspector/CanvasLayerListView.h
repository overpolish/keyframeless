/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The Layers panel content: a "Layers" header over a scrollable well that
/// will host layer rows. Ported from the old Canvas layer list as the VIEW
/// shell only - no data store / param-sync / OSC pump. With no shapes yet it
/// shows the empty state; real rows get wired in once the path model returns.
@interface CanvasLayerListView : NSView
@end

NS_ASSUME_NONNULL_END
