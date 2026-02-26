//
//  KKColors.h
//  KeyframelessKit
//
//  Created by Dom on 26/02/2026.
//

#ifndef KKColors_h
#define KKColors_h

#import <simd/simd.h>

static const simd_float4 KKColor_Primary     = (simd_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
static const simd_float4 KKColor_Outline     = (simd_float4){ 0.0f, 0.0f, 0.0f, 1.0f };
static const simd_float4 KKColor_Hover       = (simd_float4){ 0.4f, 0.8f, 0.4f, 1.0f };
static const simd_float4 KKColor_Active      = (simd_float4){ 0.2f, 0.9f, 0.2f, 1.0f };
static const simd_float4 KKColor_Transparent = (simd_float4){ 0.0f, 0.0f, 0.0f, 0.0f };

#endif /* KKColors_h */
