//
//  KKArcOSC.h
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import <KeyframelessKit/KKOnScreenControl.h>
#import <KeyframelessKit/KKOSCShaderTypes.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKArcOSC : KKOnScreenControl

/// Outer radius of the ring in canvas pixels. Default 25.
@property (nonatomic) float oscRadius;

/// Thickness of the ring stroke. Default 12.
@property (nonatomic) float strokeWidth;

/// Width of the outline around the ring. Default 2.
@property (nonatomic) float outlineWidth;

@property (nonatomic) simd_float4 primaryColor;
@property (nonatomic) simd_float4 outlineColor;
@property (nonatomic) simd_float4 hoverColor;
@property (nonatomic) simd_float4 activeColor;

/// Outline color

/// The hit radius used for mouse interaction.
@property (nonatomic, readonly) float hitRadius;

/// Half the full extent of the control. Use this in oscPositionAtTime:
/// when calculating how far to offset the OSC from the image edge.
@property (nonatomic, readonly) float oscSize;

@end

NS_ASSUME_NONNULL_END
