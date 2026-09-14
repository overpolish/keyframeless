/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The boolean-op preview overlay: renders kept (green) / removed (red)
// regions to a Metal texture (see KKPathBooleanPreviewTexture).

#import "KKPathBoolean.h"

#import "KKCGPathBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>


static void strokeAndFillCGPath(CGContextRef ctx, CGPathRef cgPath,
                                KKBezierPath *path, CGFloat w, CGFloat h,
                                CGFloat r, CGFloat g, CGFloat b) {
  // Transform from object space (0-1) to pixel space.
  CGAffineTransform xform = CGAffineTransformMake(w, 0, 0, h, 0, 0);
  CGPathRef transformed = CGPathCreateCopyByTransformingPath(cgPath, &xform);

  if (path.fillEnabled) {
    CGContextSetRGBFillColor(ctx, r, g, b, 0.25);
    CGContextAddPath(ctx, transformed);
    CGContextFillPath(ctx);
  }

  if (path.strokeEnabled) {
    CGContextSetRGBStrokeColor(ctx, r, g, b, 0.55);
    CGContextSetLineWidth(ctx, path.strokeWidth);
    CGContextSetLineCap(ctx, (CGLineCap)path.lineCap);
    CGContextSetLineJoin(ctx, (CGLineJoin)path.lineJoin);
    CGContextAddPath(ctx, transformed);
    CGContextStrokePath(ctx);
  }

  CGPathRelease(transformed);
}

id<MTLTexture>
KKPathBooleanPreviewTexture(NSArray<KKBezierPath *> *selectedPaths,
                            KKBezierPath *resultPath, CGFloat width,
                            CGFloat height, id<MTLDevice> device) {
  NSInteger pixelW = (NSInteger)width;
  NSInteger pixelH = (NSInteger)height;
  if (pixelW <= 0 || pixelH <= 0)
    return nil;

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, pixelW, pixelH, 8, pixelW * 4, cs,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx)
    return nil;

  // Draw selected paths in red (will be removed).
  for (KKBezierPath *path in selectedPaths) {
    if (path.count == 0 || path.isImage || path.isGroup)
      continue;
    CGMutablePathRef cgPath = CGPathCreateFromKKBezierPath(path);
    strokeAndFillCGPath(ctx, cgPath, path, width, height, 1.0, 0.2, 0.2);
    CGPathRelease(cgPath);
  }

  // Draw result path in green (will remain).
  if (resultPath && resultPath.count > 0) {
    CGMutablePathRef cgPath = CGPathCreateFromKKBezierPath(resultPath);
    // Use the first selected path's stroke properties for the result preview.
    KKBezierPath *styleSrc = selectedPaths.firstObject;
    if (styleSrc) {
      KKBezierPath *preview = resultPath;
      // Temporarily use source style for rendering.
      CGContextSetRGBStrokeColor(ctx, 0.2, 1.0, 0.2, 0.7);
      CGContextSetLineWidth(ctx, styleSrc.strokeWidth);
      CGContextSetLineCap(ctx, (CGLineCap)styleSrc.lineCap);
      CGContextSetLineJoin(ctx, (CGLineJoin)styleSrc.lineJoin);

      CGAffineTransform xform =
          CGAffineTransformMake(width, 0, 0, height, 0, 0);
      CGPathRef transformed =
          CGPathCreateCopyByTransformingPath(cgPath, &xform);

      if (preview.fillEnabled || styleSrc.fillEnabled) {
        CGContextSetRGBFillColor(ctx, 0.2, 1.0, 0.2, 0.25);
        CGContextAddPath(ctx, transformed);
        CGContextFillPath(ctx);
      }
      if (styleSrc.strokeEnabled) {
        CGContextAddPath(ctx, transformed);
        CGContextStrokePath(ctx);
      }
      CGPathRelease(transformed);
    }
    CGPathRelease(cgPath);
  }

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:pixelW
                                  height:pixelH
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
  [texture replaceRegion:MTLRegionMake2D(0, 0, pixelW, pixelH)
             mipmapLevel:0
               withBytes:CGBitmapContextGetData(ctx)
             bytesPerRow:pixelW * 4];

  CGContextRelease(ctx);
  return texture;
}
