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

/// Radius of the point in canvas pixels. Default 7.
@property (nonatomic) float oscRadius;

/// Width of the outline around the point. Default 2.
@property (nonatomic) float outlineWidth;

@end

NS_ASSUME_NONNULL_END
