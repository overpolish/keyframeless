/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Canvas's plugin-specific timeline inspector. For now a thin subclass of the
/// generic `KKTimelineInspectorView` (toolbar, tab bar, content area, detach,
/// live setters). Canvas-specific extras (mini-viewer renderer, OSC, guides)
/// get added back as those features are rebuilt onto the v3 timing core.
@interface CanvasInspectorView : KKTimelineInspectorView
/// Re-read the layer blob and refresh the Layers panel (on undo/redo).
- (void)reloadLayerList;
/// The host-recognized object (plugin) to open parameter actions with, so the
/// Layers panel's writes persist. Set by the plugin after creating the view.
- (void)setLayerParamActionTarget:(nullable id)target;
/// layerID of the layer whose timeline the inspector currently edits (driven by
/// the Layers panel selection; nil = topmost). The plugin's timeline-persist
/// reads this to write the edit back to the right layer.
@property(nonatomic, copy, nullable, readonly) NSString *selectedLayerID;
@end

NS_ASSUME_NONNULL_END
