//
//  KKArcOSC.h
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import <KeyframelessKit/KKOnScreenControl.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKArcOSC : KKOnScreenControl

/// Outer radius of the ring in canvas pixels. Default 25.
@property (nonatomic) float oscRadius;

/// Thickness of the ring stroke. Default 12.
@property (nonatomic) float strokeWidth;

/// Width of the outline around the ring. Default 2.
@property (nonatomic) float outlineWidth;

/// Color when idle. Default white.
@property (nonatomic) simd_float4 defaultColor;

/// Color on hover. Default soft green.
@property (nonatomic) simd_float4 hoverColor;

/// Color when pressed/dragging. Default bright green.
@property (nonatomic) simd_float4 activeColor;

/// The hit radius used for mouse interaction.
@property (nonatomic, readonly) float hitRadius;

/// Half the full extent of the control. Use this in oscPositionAtTime:
/// when calculating how far to offset the OSC from the image edge.
@property (nonatomic, readonly) float oscSize;

/// Draw an arc OSC directly into an existing command encoder.
/// Position is in Metal viewport space (origin center, Y-up).
/// Useful for compositing arc alongside other draw calls.
+ (void)drawWithEncoder:(id<MTLRenderCommandEncoder>)encoder
               position:(CGPoint)position
           viewportSize:(simd_uint2)viewportSize
          pipelineState:(id<MTLRenderPipelineState>)pipelineState
              oscRadius:(float)oscRadius
            strokeWidth:(float)strokeWidth
           outlineWidth:(float)outlineWidth
                  color:(simd_float4)color;

@end

NS_ASSUME_NONNULL_END
