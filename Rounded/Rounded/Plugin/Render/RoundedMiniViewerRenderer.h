/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it.
extern NSString *const RoundedMiniViewerDescriptorPath;

/// Reverse channel: the boundary-value popover (ViewBridge side) writes the
/// requested clip fraction here; the render side reads it in
/// `-scheduleInputs:` to also pull that frame for the preview.
extern NSString *const RoundedMiniViewerRequestPath;

/// Per-instance rendezvous paths keyed by the instance UUID. Two stacked
/// Rounded clips must read/write distinct `/tmp` files, otherwise the top
/// clip's render pollutes the feed the clip below reads (its mini-viewer shows
/// the wrong source). Falls back to the static path when `uuid` is empty.
NSString *RoundedMiniViewerDescriptorPathForUUID(NSString *_Nullable uuid);
NSString *RoundedMiniViewerRequestPathForUUID(NSString *_Nullable uuid);

/// Rounded's mini-viewer delegate: the generic crop/handle/timeline
/// scaffolding lives in `KKMiniViewerRenderer`; this subclass only supplies
/// the Rounded shader render and the radius point-handle (its OSC math).
/// MRR (non-ARC).
@interface RoundedMiniViewerRenderer : KKMiniViewerRenderer
@end

NS_ASSUME_NONNULL_END
