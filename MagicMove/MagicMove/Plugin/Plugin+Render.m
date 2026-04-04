/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Render)

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState)
    return NO;

  MagicMoveParams params;
  [pluginState getBytes:&params length:sizeof(params)];

  return [self renderDestinationImage:destinationImage
                         sourceImages:sourceImages
                             pluginID:kPluginID
                        fragmentBytes:&params
                     fragmentBytesLen:sizeof(params)
                  fragmentBufferIndex:FragmentIndex_Params
                                error:outError];
}

@end
#pragma clang diagnostic pop
