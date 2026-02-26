//
//  KKPointOSC.h
//  KeyframelessKit
//
//  Created by Dom on 26/02/2026.
//

#import <KeyframelessKit/KKOnScreenControl.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPointOSC : KKOnScreenControl

/// Radius of the point in canvas pixels. Default 8.
@property (nonatomic) float oscRadius;

/// Width of the outline around the point. Default 1.5.
@property (nonatomic) float outlineWidth;

@property (nonatomic) simd_float4 primaryColor;
@property (nonatomic) simd_float4 outlineColor;
@property (nonatomic) simd_float4 hoverColor;
@property (nonatomic) simd_float4 activeColor;

@property (nonatomic, readonly) float hitRadius;
@property (nonatomic, readonly) float oscSize;

@end

NS_ASSUME_NONNULL_END
