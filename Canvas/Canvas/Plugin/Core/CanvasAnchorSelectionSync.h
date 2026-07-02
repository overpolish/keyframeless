/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Cross-process anchor-selection sync between the viewer OSC (render/OSC XPC)
/// and the inspector mini (ViewBridge). It rides a small /tmp JSON rather than
/// kParamUIState so it stays OUT of the undo stack - selecting points is not an
/// undoable action (standard editor UX). Each surface publishes on change and
/// applies the other's on its next redraw (the param channel would notify
/// instantly but pollute cmd-Z; this trades instant-when-idle for a clean
/// undo).
///
/// `writerTag` / `readerTag` identify the surface ("osc" / "mini") so a surface
/// never re-applies its own write. `uuid` is the instance UUID: two stacked
/// Canvas clips (worse: a copy/pasted clip that clones layer IDs) must ride
/// distinct /tmp files, otherwise one clip's point selection leaks into the
/// other's surface. Empty `uuid` falls back to the shared static path.

/// Publish the current anchor selection for `layerID`.
void CanvasPublishAnchorSelection(NSString *_Nullable uuid, NSString *writerTag,
                                  NSString *_Nullable layerID,
                                  NSIndexSet *indices);

/// The selection to apply if the OTHER surface published a newer one for
/// `layerID` since this reader last consumed; nil if unchanged / different
/// layer / this reader's own write.
NSIndexSet *_Nullable CanvasConsumeAnchorSelection(NSString *_Nullable uuid,
                                                   NSString *readerTag,
                                                   NSString *_Nullable layerID);

NS_ASSUME_NONNULL_END
