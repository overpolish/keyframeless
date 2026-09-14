/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Layer blob IO for the layer list, split from CanvasLayerListView.m: reading /
// writing the kParamLayerData string, the cache-mutating _modifyPaths: helper,
// and importing dropped image / SVG files into ready-to-insert layers.

#import <KeyframelessKit/KKPlugin.h> // KKPerformUndoable
#import "CanvasLayerListView_Private.h"

#import "CanvasLayerRender.h"
#import "CanvasLocalized.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKSVGParser.h>
#import <KeyframelessKit/KKShape.h>
#import <simd/simd.h>

@implementation CanvasLayerListView (IO)

- (NSMutableArray<KKBezierPath *> *)_readPaths {
  id<PROAPIAccessing> api = self.apiManager;
  if (!api)
    return [NSMutableArray array];
  return CanvasReadLayerPaths(api, self.paramActionTarget ?: self);
}

- (void)_writePaths:(NSArray<KKBezierPath *> *)paths {
  id<PROAPIAccessing> api = self.apiManager;
  if (!api)
    return;
  KKPerformUndoable(
      api, self.paramActionTarget ?: self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        NSData *blob = [KKBezierPath blobFromPaths:paths];
        self->_selfWritePending++; // skip the echo this write will trigger
        KKWriteCustomParamString(
            setAPI, [blob base64EncodedStringWithOptions:0], kParamLayerData);
      });
}

// Mutate the cached paths, persist once, rebuild rows from the cache (no
// re-read, thumbnails reused). The new model's equivalent of the old store's
// `_modifyPaths:` (no store / param-sync / OSC pump).
- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *paths))block {
  block(_paths);
  [self _writePaths:_paths];
  [self _rebuildRows];
}

- (nullable KKBezierPath *)_imageLayerForURL:(NSURL *)url {
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:url.path];
  if (!img || img.size.width <= 0 || img.size.height <= 0)
    return nil;
  float aspect = (float)(img.size.width / img.size.height);

  const float cw = 1920.0f, ch = 1080.0f;
  float scale = fminf((cw * 0.5f) / (float)img.size.width,
                      (ch * 0.5f) / (float)img.size.height);
  float w = (float)img.size.width * scale / cw;
  float h = (float)img.size.height * scale / ch;
  float x0 = 0.5f - w / 2.0f, y0 = 0.5f - h / 2.0f;

  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.isImage = YES;
  p.imagePath = url.path;
  p.imageAspect = aspect;
  p.name = url.lastPathComponent.stringByDeletingPathExtension;
  p.strokeEnabled = NO;
  p.fillEnabled = NO;
  KKRectShape *rect = [[KKRectShape alloc] init];
  rect.min = simd_make_float2(x0, y0);
  rect.max = simd_make_float2(x0 + w, y0 + h);
  p.shape = rect;
  return p;
}

- (NSArray<KKBezierPath *> *)_svgLayersForURL:(NSURL *)url {
  NSString *svg = [NSString stringWithContentsOfURL:url
                                           encoding:NSUTF8StringEncoding
                                              error:nil];
  if (!svg.length)
    return @[];
  // The parser normalises to 0-1 object space; it needs the canvas dimensions
  // to compensate the aspect (same 1920x1080 reference the image insert uses).
  NSArray<KKBezierPath *> *imported =
      [KKSVGParser pathsFromSVGString:svg canvasWidth:1920.0f canvasHeight:1080.0f];
  if (imported.count == 0)
    return @[];
  // SVG paints first-to-last (back-to-front); the layer list is top-to-bottom
  // (topmost draws in front), so reverse to keep the stacking order.
  imported = [[imported reverseObjectEnumerator] allObjects];

  // Keep the parsed paint: fill (colour + shape) and stroke (colour + width)
  // both render now, so trust what the SVG specified. `currentColor` is
  // resolved to black up front by the parser (it isn't a real colour), so it
  // arrives as a normal black stroke rather than a placeholder.
  NSString *base = url.lastPathComponent.stringByDeletingPathExtension;

  if (imported.count == 1) {
    KKBezierPath *single = imported.firstObject;
    if (!single.name.length)
      single.name = base;
    single.parentGroupID = nil; // the caller sets the drop parent
    return @[ single ];
  }
  // Several elements: wrap them in a group named after the file (matching how
  // multi-path SVGs imported before the v3 rebuild).
  KKBezierPath *group = [[KKBezierPath alloc] init];
  group.isGroup = YES;
  group.groupID = [[NSUUID UUID] UUIDString];
  group.name = base;
  group.strokeEnabled = NO;
  group.fillEnabled = NO;
  NSMutableArray<KKBezierPath *> *out = [NSMutableArray arrayWithObject:group];
  for (NSUInteger i = 0; i < imported.count; i++) {
    KKBezierPath *child = imported[i];
    child.parentGroupID = group.groupID;
    if (!child.name.length)
      child.name = [NSString
          stringWithFormat:CLoc(@"Path %lu",
                                @"Fallback name for an unnamed SVG sub-path "
                                @"(%lu = its number)"),
                           (unsigned long)(i + 1)];
    [out addObject:child];
  }
  return out;
}

- (nullable NSImage *)_thumbnailForPath:(NSString *)imagePath {
  if (!imagePath.length)
    return nil;
  NSImage *cached = _thumbCache[imagePath];
  if (cached)
    return cached;
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:imagePath];
  if (img)
    _thumbCache[imagePath] = img;
  return img;
}

@end
