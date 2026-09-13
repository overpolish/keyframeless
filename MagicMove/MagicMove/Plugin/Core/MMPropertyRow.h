/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
@import InspectorControls;
@class MagicMovePlugin, MMPropertyLane;
@interface MMScalarRow : ICSliderRow
- (instancetype)initWithPlugin:(MagicMovePlugin *)plugin lane:(MMPropertyLane *)lane label:(NSString *)label;
@end

@interface MMVectorRow : ICInspectorRow
- (instancetype)initWithPlugin:(MagicMovePlugin *)plugin lane:(MMPropertyLane *)lane label:(NSString *)label components:(NSArray<ICInspectorComponent *> *)components;
@end
