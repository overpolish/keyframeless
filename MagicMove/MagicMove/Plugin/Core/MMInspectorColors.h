/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "Constants.h"
@import InspectorControls;

// Stable component identity, independent of selection order or visible curves.
// Keep this mapping shared by inspector decorations and the timing graph.
static inline NSArray<NSColor *> *MMInspectorColors(UInt32 parameterID) {
  NSArray<NSColor *> *palette=ICInspectorTokens.curveColors;
  switch(parameterID) {
    case MMCustomControls: return @[palette[0],palette[1]];
    case MMScaleControls: return @[palette[2],palette[3]];
    case MMRotationControls: return @[palette[5],palette[6],palette[7]];
    case MMOpacityControls: return @[palette[4]];
    case MMBlurControls: return @[palette[8]];
    case MMAnchorControls: return @[palette[9],palette[10]];
    default: return @[];
  }
}
