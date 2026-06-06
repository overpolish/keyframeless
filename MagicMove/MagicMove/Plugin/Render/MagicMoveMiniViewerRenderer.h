/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it. The
/// `...ForUUID` variants make the path per-instance so two stacked MagicMove
/// clips don't publish to the same file (which made the top clip flicker the
/// clip below it). Pass the instance UUID (`KKInstanceUUIDForAPI`); a nil/empty
/// UUID falls back to the shared default path.
extern NSString *const MagicMoveMiniViewerDescriptorPath;
NSString *MagicMoveMiniViewerDescriptorPathForUUID(NSString *_Nullable uuid);

/// Reverse channel: the boundary-value popover writes the requested clip
/// fraction here; the render side reads it in -scheduleInputs:.
extern NSString *const MagicMoveMiniViewerRequestPath;
NSString *MagicMoveMiniViewerRequestPathForUUID(NSString *_Nullable uuid);

/// MagicMove's mini-viewer delegate. Position (XY) is the only point handle;
/// the effect render falls back to the base passthrough until we add a
/// dedicated mini-viewer transform shader.
@interface MagicMoveMiniViewerRenderer : KKMiniViewerRenderer
@end

NS_ASSUME_NONNULL_END
