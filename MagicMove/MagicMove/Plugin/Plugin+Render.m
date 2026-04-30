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
  [KKPlugin multiStageRenderTickForAPI:self.apiManager
                                atTime:renderTime
                                sender:self];

  if (!pluginState)
    return NO;

  if (pluginState.length < sizeof(KKMotionBlurState) + sizeof(MagicMoveParams))
    return NO;
  KKMotionBlurState mbState;
  [pluginState getBytes:&mbState length:sizeof(mbState)];

  if (mbState.enabled) {
    __weak typeof(self) weakSelf = self;
    NSData *capturedState = pluginState;
    BOOL applied = [KKMotionBlur
        applyToDestinationImage:destinationImage
                   sourceImages:sourceImages
                          state:mbState
                     renderTime:renderTime
                    renderBlock:^BOOL(int sampleIndex,
                                      id<MTLTexture> sampleDest,
                                      id<MTLCommandBuffer> commandBuffer,
                                      NSArray<id<MTLTexture>> *inputTextures) {
                      __strong typeof(weakSelf) strongSelf = weakSelf;
                      if (!strongSelf || inputTextures.count == 0)
                        return NO;
                      NSUInteger offset =
                          sizeof(KKMotionBlurState) +
                          (NSUInteger)sampleIndex * sizeof(MagicMoveParams);
                      if (offset + sizeof(MagicMoveParams) >
                          capturedState.length)
                        return NO;
                      MagicMoveParams sampleParams;
                      [capturedState
                          getBytes:&sampleParams
                             range:NSMakeRange(offset,
                                               sizeof(MagicMoveParams))];
                      id<MTLRenderPipelineState> pipeline = [strongSelf
                          pipelineStateForPluginID:kPluginID
                                  destinationImage:destinationImage
                                      vertexShader:@"vertexShader"
                                    fragmentShader:@"fragmentShader"
                                         blendMode:
                                             KKBlendModePremultipliedAlpha];
                      if (!pipeline)
                        return NO;
                      return [strongSelf
                          encodeFullScreenQuadIntoTexture:sampleDest
                                         destinationImage:destinationImage
                                            commandBuffer:commandBuffer
                                           sourceTextures:inputTextures
                                                 commands:^(
                                                     id<MTLRenderCommandEncoder>
                                                         enc,
                                                     NSArray<id<MTLTexture>>
                                                         *texs) {
                                                   [enc setRenderPipelineState:
                                                            pipeline];
                                                   [enc
                                                       setFragmentTexture:
                                                           texs[0]
                                                                  atIndex:
                                                                      KKTextureIndex_InputImage];
                                                   [enc
                                                       setFragmentBytes:
                                                           &sampleParams
                                                                 length:
                                                                     sizeof(
                                                                         sampleParams)
                                                                atIndex:
                                                                    FragmentIndex_Params];
                                                   [enc
                                                       drawPrimitives:
                                                           MTLPrimitiveTypeTriangleStrip
                                                          vertexStart:0
                                                          vertexCount:4];
                                                 }];
                    }];
    if (applied)
      return YES;
    // Fall through on failure — render the un-blurred frame so the user
    // sees something rather than a black tile.
  }

  MagicMoveParams params;
  [pluginState getBytes:&params
                  range:NSMakeRange(sizeof(KKMotionBlurState), sizeof(params))];

  return [self renderDestinationImage:destinationImage
                         sourceImages:sourceImages
                             pluginID:kPluginID
                        fragmentBytes:&params
                     fragmentBytesLen:sizeof(params)
                  fragmentBufferIndex:FragmentIndex_Params
                                error:outError];
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError {
  *sourceTileRect = sourceImages[sourceImageIndex].imagePixelBounds;
  return YES;
}

@end
#pragma clang diagnostic pop
