/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKPlugin.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPlugin (Crop)

/// Registers crop parameters: a custom group header, a hidden expanded toggle,
/// and four percent sliders (top, bottom, left, right) starting hidden.
- (BOOL)addCropParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                         groupID:(UInt32)groupID
                      expandedID:(UInt32)expandedID
                           topID:(UInt32)topID
                        bottomID:(UInt32)bottomID
                          leftID:(UInt32)leftID
                         rightID:(UInt32)rightID
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
