/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasMiniViewerRenderer.h"
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CanvasMiniViewerRenderer ()
// Reusable Position + motion-path controller (owns the shared snap engine and
// the whole Position/Path drag-state machine). Canvas has no anchor / rotation
// in the mini, so Position is the only point handle.
@property(nonatomic, strong) KKPositionMiniController *positionMini;
// Reusable Scale transform-box controller (geometry + hit-test + drag).
@property(nonatomic, strong) KKScaleMiniController *scaleMini;
// Reusable Anchor-square controller (centre + hit-test + delta drag + Cmd-snap,
// sharing the Position controller's snap engine).
@property(nonatomic, strong) KKAnchorMiniController *anchorMini;
// Position handle centre for a content rect (proxies the base helper); called
// across the Interaction category.
- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos;
// Member-local ANCHOR pivot (Position + Anchor) in overlay points - the centre
// the rotation rings / scale box / anchor square share.
- (CGPoint)_anchorPivotForContentRect:(CGRect)cr;
@end

@interface CanvasMiniViewerRenderer (Interaction)
// The layer auto-select would pick at `p` (or nil): topmost selectable image
// layer under the cursor, honoring autoSelectEnabled + nonSelectableLayerIDs.
// Shared by the background-click selector and the hover cursor.
- (nullable NSString *)_autoSelectLayerAtPoint:(CGPoint)p
                                   contentRect:(CGRect)cr;
@end

NS_ASSUME_NONNULL_END
