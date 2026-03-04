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

/// Outer radius of the ring in canvas pixels. Default 23.
@property (nonatomic) float oscRadius;

/// Thickness of the ring stroke. Default 10.
@property (nonatomic) float strokeWidth;

/// Width of the outline around the ring. Default 2.
@property (nonatomic) float outlineWidth;

@end

NS_ASSUME_NONNULL_END
