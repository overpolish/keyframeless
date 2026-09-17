/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once

#import "Plugin.h"
#import "ShaderTypes.h"

// Geometry shared by the render entry points. The host asks for the output
// rect and the source tile before it asks for pixels, and all three answers
// have to agree on one frame geometry, so the conversions live together.

static inline BOOL MMError(NSError **error, NSString *message) {
  if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain
                                         code:kFxError_InvalidParameter
                                     userInfo:@{NSLocalizedDescriptionKey:message}];
  return NO;
}

// Square-pixel size of the whole image, with host preview/proxy scaling and
// pixel aspect removed. Zero when the host geometry is unusable.
CGSize MMImageReferenceSize(FxImageTile *image);
// Anchor in source-frame fractions and blur sigma in delivered-tile pixels.
MMTransform MMTransformForSource(MMTransform state, FxImageTile *source);
// Destination placement in source-frame fractions, for the shader's inverse.
MMTransform MMTransformForDestination(MMTransform state, FxImageTile *source,
                                      FxImageTile *destination);

@interface MagicMovePlugin (RenderGeometry)
// The frame size the inspector and on-screen controls work in, which is the
// source frame rather than the possibly grown output.
- (void)publishInspectorGeometry:(FxImageTile *)image;
@end
