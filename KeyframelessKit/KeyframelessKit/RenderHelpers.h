//
//  RenderHelpers.h
//  KeyframelessKit
//
//  Created by Dom on 24/02/2026.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/ShaderTypes.h>

NS_ASSUME_NONNULL_BEGIN

@interface KeyframelessKitRenderHelpers : NSObject

/// Generate vertices for a quad centered at a point with normalized texture coordinates (-1 to 1).
+ (void)generateQuadVertices:(KeyframelessKitVertex2D *)vertices
                      center:(CGPoint)center
                        size:(float)size;

/// Generate vertices for a quad with custom texture coordinates.
+ (void)generateQuadVertices:(KeyframelessKitVertex2D *)vertices
                      center:(CGPoint)center
                        size:(float)size
          textureCoordMinMax:(CGRect)texCoords;

/// Generate vertices for a full-screen quad.
+ (void)generateFullScreenQuadVertices:(KeyframelessKitVertex2D *)vertices;

/// Create a Metal render pass descriptor that clears the target texture with a specified color.
/// @return A configured MTLRenderPassDescriptor ready for rendering.
+ (MTLRenderPassDescriptor *)createClearRenderPassWithTexture:(id<MTLTexture>)texture
                                                   clearColor:(MTLClearColor)clearColor;



/// Create a Metal render pipeline descriptor.
/// @param blendMode Whether to enable alpha blending in the pipeline.
/// @return A configured MTLRenderPipelineDescriptor.
+ (MTLRenderPipelineDescriptor *)createPipelineDescriptorWithVertexFunction:(id<MTLFunction>)vertexFunction
                                                           fragmentFunction:(id<MTLFunction>)fragmentFunction
                                                                pixelFormat:(MTLPixelFormat)pixelFormat
                                                                  blendMode:(KKBlendMode)blendMode;

@end

NS_ASSUME_NONNULL_END
