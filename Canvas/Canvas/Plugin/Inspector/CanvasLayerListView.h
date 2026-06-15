/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// The Layers panel content: a "Layers" header over a scrollable well of layer
/// rows. Ported from the old Canvas layer list as the VIEW + minimal IO - no
/// KKCanvasStore / param-sync / OSC pump. Layers are a KKBezierPath blob in the
/// `kParamLayerData` string param; this view reads/writes it directly (via the
/// action-scope APIs) and rebuilds rows. Drop image files to add layers.
@interface CanvasLayerListView : NSView
/// Setting this reads the current layers and builds the rows.
@property(nonatomic, weak, nullable) id<PROAPIAccessing> apiManager;
/// The object passed to startAction:/endAction: when reading/writing params.
/// Must be a host-recognized parameter editor (the plugin instance); a plain
/// view the host doesn't know about opens a throwaway action whose writes are
/// discarded. Falls back to self if unset.
@property(nonatomic, weak, nullable) id paramActionTarget;
/// Re-read the layer blob and rebuild (call from the host's parameterChanged:
/// so undo/redo of the layer data is reflected here).
- (void)reloadFromParam;
@end

NS_ASSUME_NONNULL_END
