//
//  RenderHelpers.m
//  KeyframelessKit
//
//  Created by Dom on 24/02/2026.
//

#import "RenderHelpers.h"

@implementation KeyframelessKitRenderHelpers

+ (void)generateQuadVertices:(KeyframelessKitVertex2D *)vertices
                      center:(CGPoint)center
                        size:(float)size
{
    vertices[0].position = (simd_float2){ center.x - size, center.y - size };
    vertices[0].textureCoordinate = (simd_float2){ -1.0, -1.0 };
    
    vertices[1].position = (simd_float2){ center.x + size, center.y - size };
    vertices[1].textureCoordinate = (simd_float2){ 1.0, -1.0 };
    
    vertices[2].position = (simd_float2){ center.x + size, center.y + size };
    vertices[2].textureCoordinate = (simd_float2){ 1.0, 1.0 };
    
    vertices[3].position = (simd_float2){ center.x - size, center.y - size };
    vertices[3].textureCoordinate = (simd_float2){ -1.0, -1.0 };
    
    vertices[4].position = (simd_float2){ center.x + size, center.y + size };
    vertices[4].textureCoordinate = (simd_float2){ 1.0, 1.0 };
    
    vertices[5].position = (simd_float2){ center.x - size, center.y + size };
    vertices[5].textureCoordinate = (simd_float2){ -1.0, 1.0 };
}

+ (void)generateQuadVertices:(KeyframelessKitVertex2D *)vertices
                      center:(CGPoint)center
                        size:(float)size
          textureCoordMinMax:(CGRect)texCoords
{
    float minX = texCoords.origin.x;
    float minY = texCoords.origin.y;
    float maxX = minX + texCoords.size.width;
    float maxY = minY + texCoords.size.height;
    
    vertices[0].position = (simd_float2){ center.x - size, center.y - size };
    vertices[0].textureCoordinate = (simd_float2){ minX, minY };
    
    vertices[1].position = (simd_float2){ center.x + size, center.y - size };
    vertices[1].textureCoordinate = (simd_float2){ maxX, minY };
    
    vertices[2].position = (simd_float2){ center.x + size, center.y + size };
    vertices[2].textureCoordinate = (simd_float2){ maxX, maxY };
    
    vertices[3].position = (simd_float2){ center.x - size, center.y - size };
    vertices[3].textureCoordinate = (simd_float2){ minX, minY };
    
    vertices[4].position = (simd_float2){ center.x + size, center.y + size };
    vertices[4].textureCoordinate = (simd_float2){ maxX, maxY };
    
    vertices[5].position = (simd_float2){ center.x - size, center.y + size };
    vertices[5].textureCoordinate = (simd_float2){ minX, maxY };
}

+ (void)generateFullScreenQuadVertices:(KeyframelessKitVertex2D *)vertices
{
    // Fullscreen quad in clip space (-1 to 1)
    vertices[0].position = (simd_float2){ -1.0, -1.0 };
    vertices[0].textureCoordinate = (simd_float2){ 0.0, 1.0 };
    
    vertices[1].position = (simd_float2){ 1.0, -1.0 };
    vertices[1].textureCoordinate = (simd_float2){ 1.0, 1.0 };
    
    vertices[2].position = (simd_float2){ 1.0, 1.0 };
    vertices[2].textureCoordinate = (simd_float2){ 1.0, 0.0 };
    
    vertices[3].position = (simd_float2){ -1.0, -1.0 };
    vertices[3].textureCoordinate = (simd_float2){ 0.0, 1.0 };
    
    vertices[4].position = (simd_float2){ 1.0, 1.0 };
    vertices[4].textureCoordinate = (simd_float2){ 1.0, 0.0 };
    
    vertices[5].position = (simd_float2){ -1.0, 1.0 };
    vertices[5].textureCoordinate = (simd_float2){ 0.0, 0.0 };
}

+ (nonnull MTLRenderPassDescriptor *)createClearRenderPassWithTexture:(nonnull id<MTLTexture>)texture
                                                           clearColor:(MTLClearColor)clearColor {
    MTLRenderPassColorAttachmentDescriptor *colorAttachment = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
    colorAttachment.texture = texture;
    colorAttachment.clearColor = clearColor;
    colorAttachment.loadAction = MTLLoadActionClear;
    colorAttachment.storeAction = MTLStoreActionStore;
    
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0] = colorAttachment;
    
    return renderPassDescriptor;
}

+ (nonnull MTLRenderPipelineDescriptor *)createOSCPipelineDescriptorWithVertexFunction:(nonnull id<MTLFunction>)vertexFunction
                                                                      fragmentFunction:(nonnull id<MTLFunction>)fragmentFunction pixelFormat:(MTLPixelFormat)pixelFormat blendingEnabled:(BOOL)enableBlending {
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label = @"OSC Pipeline";
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat;
    
    if (enableBlending) {
        pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    }
    
    return pipelineDescriptor;
}

@end
