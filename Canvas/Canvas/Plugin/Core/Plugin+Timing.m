/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

// Descriptor for an animatable per-path property. Adding a new animatable
// property in Canvas means adding one entry to `_kkAnimatableProperties()` —
// nothing else in this file branches on the property identity.
//
// readPath / writePath operate on NSArray<NSNumber *> so a single descriptor
// can represent a Float (1 scalar), a Point (2 scalars), or a Bool (1 scalar
// 0/1). The kind dictates how values are read from / written to FxPlug.
@interface KKCanvasAnimProp : NSObject
@property(copy) NSString *label;
@property UInt32 paramID;
/// Optional second FxPlug param ID for Point-kind lanes whose two
/// components live in *separate* float params (mirrors MagicMove's
/// Scale-as-two-floats-but-one-lane pattern). 0 = unused (default).
@property UInt32 secondaryParamID;
/// Optional extra bool param appended as a 3rd component on the lane.
/// Used by Position (rotate-with-motion). 0 = unused.
@property UInt32 extraBoolParamID;
@property KKAnimatableParamKind kind;
@property(copy) BOOL (^enabledForPath)(KKBezierPath *p);
@property(copy) NSArray<NSNumber *> * (^readPath)(KKBezierPath *p);
@property(copy) void (^writePath)(KKBezierPath *p, NSArray<NSNumber *> *vals);
+ (instancetype)propWithLabel:(NSString *)label
                      paramID:(UInt32)paramID
             secondaryParamID:(UInt32)secondaryParamID
                         kind:(KKAnimatableParamKind)kind
                      enabled:(BOOL (^)(KKBezierPath *))enabled
                         read:(NSArray<NSNumber *> * (^)(KKBezierPath *))read
                        write:(void (^)(KKBezierPath *,
                                        NSArray<NSNumber *> *))write;
@end
@implementation KKCanvasAnimProp
+ (instancetype)propWithLabel:(NSString *)label
                      paramID:(UInt32)paramID
             secondaryParamID:(UInt32)secondaryParamID
                         kind:(KKAnimatableParamKind)kind
                      enabled:(BOOL (^)(KKBezierPath *))enabled
                         read:(NSArray<NSNumber *> * (^)(KKBezierPath *))read
                        write:(void (^)(KKBezierPath *,
                                        NSArray<NSNumber *> *))write {
  KKCanvasAnimProp *p = [self new];
  p.label = label;
  p.paramID = paramID;
  p.secondaryParamID = secondaryParamID;
  p.kind = kind;
  p.enabledForPath = enabled;
  p.readPath = read;
  p.writePath = write;
  return p;
}
@end

// --- FxPlug param read/write helpers, dispatched on KKAnimatableParamKind. ---

static NSArray<NSNumber *> *
_kkReadParamForDesc(id<FxParameterRetrievalAPI_v6> getAPI,
                    KKCanvasAnimProp *desc, CMTime time) {
  switch (desc.kind) {
  case KKAnimatableParamKindPoint: {
    if (desc.secondaryParamID) {
      // Two-float Point: x lives in primary param, y in secondary.
      double x = 1, y = 1;
      [getAPI getFloatValue:&x fromParameter:desc.paramID atTime:time];
      [getAPI getFloatValue:&y fromParameter:desc.secondaryParamID atTime:time];
      return @[ @(x), @(y) ];
    }
    double x = 0, y = 0;
    [getAPI getXValue:&x YValue:&y fromParameter:desc.paramID atTime:time];
    if (desc.extraBoolParamID) {
      BOOL b = NO;
      [getAPI getBoolValue:&b fromParameter:desc.extraBoolParamID atTime:time];
      return @[ @(x), @(y), @(b ? 1.0 : 0.0) ];
    }
    return @[ @(x), @(y) ];
  }
  case KKAnimatableParamKindBool: {
    BOOL b = NO;
    [getAPI getBoolValue:&b fromParameter:desc.paramID atTime:time];
    return @[ @(b ? 1.0 : 0.0) ];
  }
  case KKAnimatableParamKindColor: {
    double r = 0, g = 0, b = 0;
    [getAPI getRedValue:&r
             greenValue:&g
              blueValue:&b
          fromParameter:desc.paramID
                 atTime:time];
    return @[ @(r), @(g), @(b) ];
  }
  case KKAnimatableParamKindGradient: {
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:desc.paramID];
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
    return stops ? KKGradientFlatFromStops(stops) : @[];
  }
  case KKAnimatableParamKindFloat:
  default: {
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:desc.paramID atTime:time];
    return @[ @(v) ];
  }
  }
}

static void _kkWriteParamForDesc(id<FxParameterSettingAPI_v5> setAPI,
                                 KKCanvasAnimProp *desc,
                                 NSArray<NSNumber *> *vals, CMTime time) {
  switch (desc.kind) {
  case KKAnimatableParamKindPoint:
    if (desc.secondaryParamID) {
      if (vals.count >= 2) {
        [setAPI setFloatValue:vals[0].doubleValue
                  toParameter:desc.paramID
                       atTime:time];
        [setAPI setFloatValue:vals[1].doubleValue
                  toParameter:desc.secondaryParamID
                       atTime:time];
      }
    } else if (vals.count >= 2) {
      [setAPI setXValue:vals[0].doubleValue
                 YValue:vals[1].doubleValue
            toParameter:desc.paramID
                 atTime:time];
      if (desc.extraBoolParamID && vals.count >= 3) {
        [setAPI setBoolValue:vals[2].doubleValue >= 0.5
                 toParameter:desc.extraBoolParamID
                      atTime:time];
      }
    }
    break;
  case KKAnimatableParamKindBool:
    if (vals.count >= 1)
      [setAPI setBoolValue:vals[0].doubleValue >= 0.5
               toParameter:desc.paramID
                    atTime:time];
    break;
  case KKAnimatableParamKindColor:
    if (vals.count >= 3) {
      [setAPI setRedValue:vals[0].doubleValue
               greenValue:vals[1].doubleValue
                blueValue:vals[2].doubleValue
              toParameter:desc.paramID
                   atTime:time];
    }
    break;
  case KKAnimatableParamKindGradient: {
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromFlat(vals);
    if (stops) {
      NSString *json = KKGradientJSONFromStops(stops);
      if (json)
        [setAPI setStringParameterValue:json toParameter:desc.paramID];
    }
    break;
  }
  case KKAnimatableParamKindFloat:
  default:
    if (vals.count >= 1)
      [setAPI setFloatValue:vals[0].doubleValue
                toParameter:desc.paramID
                     atTime:time];
    break;
  }
}

// Gradient lanes interpolate to a flat LUT (`KK_GRADIENT_LUT_SIZE × [r,g,b]`)
// rather than back to the 5-tuple stop format the path stores. Convert that
// LUT into evenly-spaced stops so the existing JSON-driven render path picks
// up the per-frame value. Falls back to `KKGradientStopsFromFlat` for callers
// (e.g. inspector pushes) that hand us the original stop layout.
static NSArray<KKGradientStop *> *
_kkStopsFromLaneValues(NSArray<NSNumber *> *vals) {
  if (vals.count == (NSUInteger)(KK_GRADIENT_LUT_SIZE * 3)) {
    NSMutableArray<KKGradientStop *> *stops =
        [NSMutableArray arrayWithCapacity:KK_GRADIENT_LUT_SIZE];
    for (NSInteger i = 0; i < KK_GRADIENT_LUT_SIZE; i++) {
      double t = (double)i / (double)(KK_GRADIENT_LUT_SIZE - 1);
      NSColor *c = [NSColor colorWithSRGBRed:vals[i * 3 + 0].doubleValue
                                       green:vals[i * 3 + 1].doubleValue
                                        blue:vals[i * 3 + 2].doubleValue
                                       alpha:1.0];
      [stops addObject:[KKGradientStop stopWithPosition:t color:c]];
    }
    return stops;
  }
  return KKGradientStopsFromFlat(vals);
}

static BOOL _kkValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++) {
    if (fabs(a[i].doubleValue - b[i].doubleValue) > 1e-6)
      return NO;
  }
  return YES;
}

static NSArray<KKCanvasAnimProp *> *_kkAnimatableProperties(void) {
  static NSArray<KKCanvasAnimProp *> *sProps = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    BOOL (^transformEnabled)(KKBezierPath *) = ^BOOL(KKBezierPath *p) {
      return p.transformEnabled;
    };

    KKCanvasAnimProp *strokeWidth =
        [KKCanvasAnimProp propWithLabel:@"Start Width"
            paramID:kParamStrokeWidth
            secondaryParamID:0
            kind:KKAnimatableParamKindFloat
            enabled:^BOOL(KKBezierPath *p) {
              return p.strokeEnabled && !p.isGroup;
            }
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              return @[ @(p.strokeWidth) ];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              if (vals.count >= 1)
                p.strokeWidth = vals[0].floatValue;
            }];

    // End Width is gated on KKVisStrokeOpen | KKVisOpenPath — only animate
    // for stroked open paths (closed paths have no taper end).
    KKCanvasAnimProp *endWidth = [KKCanvasAnimProp propWithLabel:@"End Width"
        paramID:kParamEndWidth
        secondaryParamID:0
        kind:KKAnimatableParamKindFloat
        enabled:^BOOL(KKBezierPath *p) {
          return p.strokeEnabled && !p.isGroup && !p.closed;
        }
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.endWidth) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 1)
            p.endWidth = vals[0].floatValue;
        }];

    // Opacity FxPlug param is 0–100 but path stores 0–1. Lanes carry
    // FxPlug-space values (matches kkPushParamToLane's _kkReadParamForDesc),
    // so scale on the path boundary.
    KKCanvasAnimProp *opacity = [KKCanvasAnimProp propWithLabel:@"Opacity"
        paramID:kParamOpacity
        secondaryParamID:0
        kind:KKAnimatableParamKindFloat
        enabled:^BOOL(KKBezierPath *p) {
          return !p.isGroup;
        }
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.opacity * 100.0) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 1)
            p.opacity = vals[0].floatValue / 100.0f;
        }];

    BOOL (^sketchOnPath)(KKBezierPath *) = ^BOOL(KKBezierPath *p) {
      return p.sketchEnabled && !p.isGroup && !p.isImage;
    };
    KKCanvasAnimProp *sketchRoughness =
        [KKCanvasAnimProp propWithLabel:@"Sketch Roughness"
            paramID:kParamSketchRoughness
            secondaryParamID:0
            kind:KKAnimatableParamKindFloat
            enabled:sketchOnPath
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              return @[ @(p.sketchRoughness) ];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              if (vals.count >= 1)
                p.sketchRoughness = vals[0].floatValue;
            }];
    KKCanvasAnimProp *sketchBowing =
        [KKCanvasAnimProp propWithLabel:@"Sketch Bowing"
            paramID:kParamSketchBowing
            secondaryParamID:0
            kind:KKAnimatableParamKindFloat
            enabled:sketchOnPath
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              return @[ @(p.sketchBowing) ];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              if (vals.count >= 1)
                p.sketchBowing = vals[0].floatValue;
            }];

    // Position uses 0.5,0.5 as neutral (FCP convention); the path stores the
    // offset from neutral so render-time translation is just translateBy:.
    KKCanvasAnimProp *position = [KKCanvasAnimProp propWithLabel:@"Position"
        paramID:kParamPosition
        secondaryParamID:0
        kind:KKAnimatableParamKindPoint
        enabled:transformEnabled
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[
            @(0.5 + p.translateX), @(0.5 + p.translateY),
            @(p.rotateWithMotion ? 1.0 : 0.0)
          ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 2) {
            p.translateX = vals[0].floatValue - 0.5f;
            p.translateY = vals[1].floatValue - 0.5f;
          }
          if (vals.count >= 3)
            p.rotateWithMotion = vals[2].doubleValue >= 0.5;
        }];
    position.extraBoolParamID = kParamRotateWithMotion;

    // Single Scale lane carrying [scaleX, scaleY] — mirrors MagicMove. The
    // two inspector sliders live in separate float FxPlug params; the lane
    // reads/writes both via primary + secondary IDs.
    KKCanvasAnimProp *scale = [KKCanvasAnimProp propWithLabel:@"Scale"
        paramID:kParamScaleX
        secondaryParamID:kParamScaleY
        kind:KKAnimatableParamKindPoint
        enabled:transformEnabled
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.scaleX), @(p.scaleY) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 2) {
            p.scaleX = vals[0].floatValue;
            p.scaleY = vals[1].floatValue;
          }
        }];

    KKCanvasAnimProp *anchor = [KKCanvasAnimProp propWithLabel:@"Anchor"
        paramID:kParamAnchor
        secondaryParamID:0
        kind:KKAnimatableParamKindPoint
        enabled:transformEnabled
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.anchorX), @(p.anchorY) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 2) {
            p.anchorX = vals[0].floatValue;
            p.anchorY = vals[1].floatValue;
          }
        }];

    KKCanvasAnimProp * (^transformFloatProp)(NSString *, UInt32,
                                             float (^)(KKBezierPath *),
                                             void (^)(KKBezierPath *, float)) =
        ^(NSString *label, UInt32 paramID, float (^getter)(KKBezierPath *),
          void (^setter)(KKBezierPath *, float)) {
          return [KKCanvasAnimProp propWithLabel:label
              paramID:paramID
              secondaryParamID:0
              kind:KKAnimatableParamKindFloat
              enabled:transformEnabled
              read:^NSArray<NSNumber *> *(KKBezierPath *p) {
                return @[ @(getter(p)) ];
              }
              write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
                if (vals.count >= 1)
                  setter(p, vals[0].floatValue);
              }];
        };

    KKCanvasAnimProp *rotZ = transformFloatProp(
        @"Rot Z", kParamRotation,
        ^(KKBezierPath *p) {
          return p.rotationZ;
        },
        ^(KKBezierPath *p, float v) {
          p.rotationZ = v;
        });
    KKCanvasAnimProp *rotX = transformFloatProp(
        @"Rot X", kParamRotationX,
        ^(KKBezierPath *p) {
          return p.rotationX;
        },
        ^(KKBezierPath *p, float v) {
          p.rotationX = v;
        });
    KKCanvasAnimProp *rotY = transformFloatProp(
        @"Rot Y", kParamRotationY,
        ^(KKBezierPath *p) {
          return p.rotationY;
        },
        ^(KKBezierPath *p, float v) {
          p.rotationY = v;
        });

    BOOL (^strokeOnPath)(KKBezierPath *) = ^BOOL(KKBezierPath *p) {
      return p.strokeEnabled && !p.isGroup;
    };
    KKCanvasAnimProp *drawOnStart =
        [KKCanvasAnimProp propWithLabel:@"Draw On Start"
            paramID:kParamDrawOnStart
            secondaryParamID:0
            kind:KKAnimatableParamKindFloat
            enabled:strokeOnPath
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              return @[ @(p.drawOnStart) ];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              if (vals.count >= 1)
                p.drawOnStart = vals[0].floatValue;
            }];
    KKCanvasAnimProp *drawOnEnd = [KKCanvasAnimProp propWithLabel:@"Draw On End"
        paramID:kParamDrawOnEnd
        secondaryParamID:0
        kind:KKAnimatableParamKindFloat
        enabled:strokeOnPath
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.drawOnEnd) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 1)
            p.drawOnEnd = vals[0].floatValue;
        }];
    KKCanvasAnimProp *drawOnOrigin =
        [KKCanvasAnimProp propWithLabel:@"Draw On Origin"
            paramID:kParamDrawOnOrigin
            secondaryParamID:0
            kind:KKAnimatableParamKindFloat
            enabled:strokeOnPath
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              return @[ @(p.drawOnOrigin) ];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              if (vals.count >= 1)
                p.drawOnOrigin = vals[0].floatValue;
            }];

    KKCanvasAnimProp *strokeColor =
        [KKCanvasAnimProp propWithLabel:@"Stroke Color"
            paramID:kParamStrokeColor
            secondaryParamID:0
            kind:KKAnimatableParamKindColor
            enabled:^BOOL(KKBezierPath *p) {
              return p.strokeEnabled && !p.isGroup && p.strokeColorMode == 0;
            }
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              return @[ @(p.strokeR), @(p.strokeG), @(p.strokeB) ];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              if (vals.count >= 3) {
                p.strokeR = vals[0].floatValue;
                p.strokeG = vals[1].floatValue;
                p.strokeB = vals[2].floatValue;
              }
            }];

    KKCanvasAnimProp *strokeGradient =
        [KKCanvasAnimProp propWithLabel:@"Stroke Gradient"
            paramID:kParamStrokeGradientData
            secondaryParamID:0
            kind:KKAnimatableParamKindGradient
            enabled:^BOOL(KKBezierPath *p) {
              return p.strokeEnabled && !p.isGroup && p.strokeColorMode == 1;
            }
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              NSArray<KKGradientStop *> *stops =
                  KKGradientStopsFromJSON(p.strokeGradientJSON);
              return stops ? KKGradientFlatFromStops(stops) : @[];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              NSArray<KKGradientStop *> *stops = _kkStopsFromLaneValues(vals);
              if (stops)
                p.strokeGradientJSON = KKGradientJSONFromStops(stops);
            }];

    KKCanvasAnimProp *fillColor = [KKCanvasAnimProp propWithLabel:@"Fill Color"
        paramID:kParamFillColor
        secondaryParamID:0
        kind:KKAnimatableParamKindColor
        enabled:^BOOL(KKBezierPath *p) {
          return p.fillEnabled && !p.isGroup && p.fillColorMode == 0;
        }
        read:^NSArray<NSNumber *> *(KKBezierPath *p) {
          return @[ @(p.fillR), @(p.fillG), @(p.fillB) ];
        }
        write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
          if (vals.count >= 3) {
            p.fillR = vals[0].floatValue;
            p.fillG = vals[1].floatValue;
            p.fillB = vals[2].floatValue;
          }
        }];

    KKCanvasAnimProp *fillGradient =
        [KKCanvasAnimProp propWithLabel:@"Fill Gradient"
            paramID:kParamFillGradientData
            secondaryParamID:0
            kind:KKAnimatableParamKindGradient
            enabled:^BOOL(KKBezierPath *p) {
              return p.fillEnabled && !p.isGroup && p.fillColorMode == 1;
            }
            read:^NSArray<NSNumber *> *(KKBezierPath *p) {
              NSArray<KKGradientStop *> *stops =
                  KKGradientStopsFromJSON(p.fillGradientJSON);
              return stops ? KKGradientFlatFromStops(stops) : @[];
            }
            write:^(KKBezierPath *p, NSArray<NSNumber *> *vals) {
              NSArray<KKGradientStop *> *stops = _kkStopsFromLaneValues(vals);
              if (stops)
                p.fillGradientJSON = KKGradientJSONFromStops(stops);
            }];

    sProps = @[
      drawOnStart, drawOnEnd, drawOnOrigin, strokeWidth, endWidth, strokeColor,
      strokeGradient, fillColor, fillGradient, opacity, sketchRoughness,
      sketchBowing, position, scale, anchor, rotZ, rotX, rotY
    ];
  });
  return sProps;
}

static KKCanvasAnimProp *_kkPropForLabel(NSString *label) {
  for (KKCanvasAnimProp *d in _kkAnimatableProperties())
    if ([d.label isEqualToString:label])
      return d;
  return nil;
}

static KKCanvasAnimProp *_kkPropForParamID(UInt32 paramID) {
  for (KKCanvasAnimProp *d in _kkAnimatableProperties())
    if (d.paramID == paramID || d.secondaryParamID == paramID ||
        d.extraBoolParamID == paramID)
      return d;
  return nil;
}

static NSMutableArray<KKBezierPath *> *
_kkReadPaths(id<FxParameterRetrievalAPI_v6> getAPI) {
  NSString *str = nil;
  [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length == 0)
    return [NSMutableArray array];
  NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
  return [KKBezierPath pathsFromBlob:blob];
}

static void _kkWritePaths(id<FxParameterSettingAPI_v5> setAPI,
                          NSArray<KKBezierPath *> *paths) {
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  [setAPI setStringParameterValue:[blob base64EncodedStringWithOptions:0]
                      toParameter:kParamPathData];
}

static KKBezierPath *_kkPathByLayerID(NSArray<KKBezierPath *> *paths,
                                      NSString *layerID) {
  if (layerID.length == 0)
    return nil;
  for (KKBezierPath *p in paths)
    if ([p.layerID isEqualToString:layerID])
      return p;
  return nil;
}

static NSString *_kkGroupLabelForPath(KKBezierPath *p, NSUInteger idx) {
  return p.name.length
             ? p.name
             : [NSString stringWithFormat:@"Layer %lu", (unsigned long)idx];
}

static KKTimingLane *_kkBuildLane(KKCanvasAnimProp *desc, KKBezierPath *p,
                                  NSUInteger idx, NSSet<NSString *> *oscLabels,
                                  NSSet<NSString *> *oscDefaultOff) {
  KKTimingLane *lane = [KKTimingLane defaultLaneForLabel:desc.label
                                              baseValues:desc.readPath(p)];
  // Two-float Point lanes (Scale-style: independent X/Y sliders, single
  // sequencer lane) report two Float component kinds — matches MagicMove.
  if (desc.kind == KKAnimatableParamKindPoint && desc.secondaryParamID) {
    lane.valueComponentKinds =
        @[ @(KKAnimatableParamKindFloat), @(KKAnimatableParamKindFloat) ];
  } else if (desc.kind == KKAnimatableParamKindPoint && desc.extraBoolParamID) {
    lane.valueComponentKinds =
        @[ @(KKAnimatableParamKindPoint), @(KKAnimatableParamKindBool) ];
  } else {
    lane.valueComponentKinds = @[ @(desc.kind) ];
  }
  lane.groupKey = p.layerID;
  lane.groupLabel = _kkGroupLabelForPath(p, idx);
  lane.hasOSC = [oscLabels containsObject:desc.label];
  if (lane.hasOSC && [oscDefaultOff containsObject:desc.label])
    lane.oscVisible = NO;
  return lane;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation CanvasPlugin (Timing)

+ (void)kkApplyLanes:(NSArray<KKTimingLane *> *)lanes
          atFraction:(double)frac
        effectDurSec:(double)effectDurSec
             toPaths:(NSArray<KKBezierPath *> *)paths {
  if (!lanes.count || !paths.count)
    return;
  // Index lanes by (groupKey, propertyLabel).
  NSMutableDictionary<NSString *, KKTimingLane *> *byKey =
      [NSMutableDictionary dictionary];
  for (KKTimingLane *l in lanes) {
    if (!l.enabled || !l.groupKey.length || !l.propertyLabel.length)
      continue;
    byKey[[NSString
        stringWithFormat:@"%@\x1f%@", l.groupKey, l.propertyLabel]] = l;
  }
  if (!byKey.count)
    return;
  NSArray<KKCanvasAnimProp *> *props = _kkAnimatableProperties();
  for (KKBezierPath *p in paths) {
    if (p.layerID.length == 0)
      continue;
    for (KKCanvasAnimProp *desc in props) {
      KKTimingLane *lane =
          byKey[[NSString stringWithFormat:@"%@\x1f%@", p.layerID, desc.label]];
      if (!lane)
        continue;
      NSArray<NSNumber *> *vals = KKTimingLaneValueAtFraction(lane, frac);
      // Position lane: when the active transition has a custom bezier
      // motion path, traverse the curve instead of taking the engine's
      // linearly-interpolated x/y.
      if (desc.kind == KKAnimatableParamKindPoint && vals.count >= 2) {
        KKTimingSegment *active =
            KKTimingSegmentForFraction(lane.segments, frac);
        NSUInteger idx = active
                             ? [lane.segments indexOfObjectIdenticalTo:active]
                             : NSNotFound;
        NSArray<NSNumber *> *fromVals =
            (idx != NSNotFound) ? KKTimingBoundaryBefore(idx, lane.segments)
                                : nil;
        NSArray<NSNumber *> *toVals =
            (idx != NSNotFound) ? KKTimingBoundaryAfter(idx, lane.segments)
                                : nil;
        if (active && fromVals.count >= 2 && toVals.count >= 2) {
          double segDur = active.end - active.start;
          double t = (segDur > 0) ? (frac - active.start) / segDur : 1.0;
          t = MAX(0.0, MIN(1.0, t));
          BOOL isAnimateOut = (idx == lane.segments.count - 1);
          simd_float2 pt;
          if (KKEvaluateBezierPathPosition(
                  active, isAnimateOut, t,
                  (simd_float2){(float)fromVals[0].doubleValue,
                                (float)fromVals[1].doubleValue},
                  (simd_float2){(float)toVals[0].doubleValue,
                                (float)toVals[1].doubleValue},
                  &pt)) {
            // Preserve any extra-component values (e.g. rotate-with-motion
            // bool on Position) — only the x/y override.
            NSMutableArray<NSNumber *> *replaced =
                [NSMutableArray arrayWithObjects:@(pt.x), @(pt.y), nil];
            for (NSUInteger k = 2; k < vals.count; k++)
              [replaced addObject:vals[k]];
            vals = replaced;
          }
        }
      }
      if (vals.count >= 1)
        desc.writePath(p, vals);
    }
  }

  if (effectDurSec > 0) {
    double window = KKRotateWithMotionWindowSeconds;
    double dFrac = window / effectDurSec;
    double prevFrac = MAX(0.0, frac - dFrac);
    if (prevFrac != frac) {
      for (KKBezierPath *p in paths) {
        if (!p.rotateWithMotion || p.layerID.length == 0)
          continue;
        KKTimingLane *posLane = byKey[
            [NSString stringWithFormat:@"%@\x1f%@", p.layerID, @"Position"]];
        if (!posLane)
          continue;
        NSArray<NSNumber *> *prev =
            KKTimingLaneValueAtFraction(posLane, prevFrac);
        if (prev.count < 2)
          continue;
        double prevX = prev[0].doubleValue;
        double posX = 0.5 + p.translateX;
        double vx = (posX - prevX) / window;
        p.rotationZ -= (float)KKRotateWithMotionDeltaRadians(vx);
      }
    }
  }
}

- (NSArray<KKTimingLane *> *)defaultLanesAtTime:(CMTime)time
                                    paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                    paramGetAPI {
  NSArray<KKBezierPath *> *paths = _kkReadPaths(paramGetAPI);
  NSArray<KKCanvasAnimProp *> *props = _kkAnimatableProperties();
  NSSet<NSString *> *oscLabels = [self animatablePropertyLabelsWithOSC];
  NSSet<NSString *> *oscDefaultOff =
      [self animatablePropertyLabelsWithOSCDefaultOff];
  NSMutableArray<KKTimingLane *> *lanes = [NSMutableArray array];
  NSUInteger idx = 0;
  for (KKBezierPath *p in paths) {
    idx++;
    if (p.layerID.length == 0)
      continue;
    for (KKCanvasAnimProp *desc in props) {
      if (desc.enabledForPath(p))
        [lanes addObject:_kkBuildLane(desc, p, idx, oscLabels, oscDefaultOff)];
    }
  }
  return lanes.count ? lanes : nil;
}

- (NSArray<KKTimingLane *> *)reconcileLanes:(NSArray<KKTimingLane *> *)existing
                                     atTime:(CMTime)time
                                paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                paramGetAPI {
  NSArray<KKBezierPath *> *paths = _kkReadPaths(paramGetAPI);
  NSArray<KKCanvasAnimProp *> *props = _kkAnimatableProperties();
  NSSet<NSString *> *oscLabels = [self animatablePropertyLabelsWithOSC];
  NSSet<NSString *> *oscDefaultOff =
      [self animatablePropertyLabelsWithOSCDefaultOff];

  // Index existing lanes by (groupKey, propertyLabel) so we can carry forward
  // segment data when a path/property is still present.
  NSMutableDictionary<NSString *, KKTimingLane *> *byKey =
      [NSMutableDictionary dictionary];
  for (KKTimingLane *l in existing) {
    if (!l.groupKey.length || !l.propertyLabel.length)
      continue;
    byKey[[NSString
        stringWithFormat:@"%@\x1f%@", l.groupKey, l.propertyLabel]] = l;
  }

  NSMutableArray<KKTimingLane *> *out = [NSMutableArray array];
  NSUInteger idx = 0;
  for (KKBezierPath *p in paths) {
    idx++;
    if (p.layerID.length == 0)
      continue;
    NSString *liveLabel = _kkGroupLabelForPath(p, idx);
    for (KKCanvasAnimProp *desc in props) {
      BOOL applies = desc.enabledForPath(p);
      BOOL liveHasOSC = [oscLabels containsObject:desc.label];
      NSString *key =
          [NSString stringWithFormat:@"%@\x1f%@", p.layerID, desc.label];
      KKTimingLane *prev = byKey[key];
      if (prev) {
        if (![prev.groupLabel isEqualToString:liveLabel] ||
            prev.pluginVisible != applies || prev.hasOSC != liveHasOSC) {
          KKTimingLane *m = [prev copy];
          m.groupLabel = liveLabel;
          m.pluginVisible = applies;
          m.hasOSC = liveHasOSC;
          prev = m;
        }
        [out addObject:prev];
      } else if (applies) {
        [out addObject:_kkBuildLane(desc, p, idx, oscLabels, oscDefaultOff)];
      }
    }
  }
  return out;
}

- (NSArray<NSNumber *> *)currentValuesForLaneLabel:(NSString *)label
                                          groupKey:(NSString *)groupKey
                                            atTime:(CMTime)time {
  KKCanvasAnimProp *desc = _kkPropForLabel(label);
  if (!desc)
    return nil;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  KKBezierPath *p = _kkPathByLayerID(_kkReadPaths(getAPI), groupKey);
  if (!p)
    return nil;
  return desc.readPath(p);
}

/// Returns the layerID of the currently-selected layer (path or group), or
/// nil if there's no single selection. Used to scope inspector-slider writes
/// (the slider only reflects the selected layer; lanes for other layers must
/// stay independent of slider edits).
- (NSString *)_kkSelectedLayerID {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  NSIndexSet *sel = uuid ? KKCanvasCurrentSelection(uuid) : nil;
  if (sel.count != 1)
    return nil;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSArray<KKBezierPath *> *paths = _kkReadPaths(getAPI);
  NSUInteger idx = sel.firstIndex;
  if (idx >= paths.count)
    return nil;
  return paths[idx].layerID;
}

- (BOOL)applyLaneValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label
               groupKey:(NSString *)groupKey
                 atTime:(CMTime)time {
  KKCanvasAnimProp *desc = _kkPropForLabel(label);
  if (!desc || values.count < 1)
    return NO;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI)
    return NO;
  NSMutableArray<KKBezierPath *> *paths = _kkReadPaths(getAPI);
  KKBezierPath *p = _kkPathByLayerID(paths, groupKey);
  if (!p)
    return NO;
  desc.writePath(p, values);
  _kkWritePaths(setAPI, paths);

  // If this lane's layer is the one currently shown in the inspector, push
  // the value into the slider's FxPlug param so the slider reflects the
  // segment's value. Other layers' lanes stay independent of the slider —
  // we never write the param for them.
  if ([groupKey isEqualToString:[self _kkSelectedLayerID]]) {
    _kkWriteParamForDesc(setAPI, desc, values, time);
  }
  return YES;
}

- (void)setEditingDisabled:(BOOL)disabled
              forLaneLabel:(NSString *)label
                  groupKey:(NSString *)groupKey {
  // Canvas has no per-layer FxPlug params to flag; HTH transitions are
  // surfaced by the sequencer UI alone.
}

/// Routes an inspector-slider change into the selected layer's lane:
/// writes the new value into that lane's currently-selected segment.
/// No-op when there's no single-layer selection or no matching lane.
/// Mirrors MagicMove's `_mmHandleAnimatableParameterChange:`, scoped
/// per-layer via `groupKey`.
- (void)kkPushParamToLane:(UInt32)paramID {
  KKCanvasAnimProp *desc = _kkPropForParamID(paramID);
  if (!desc)
    return;
  NSString *selID = [self _kkSelectedLayerID];
  if (selID.length == 0)
    return;
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actAPI)
    return;
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI) {
    [actAPI endAction:self];
    return;
  }
  CMTime now = [actAPI currentTime];
  NSArray<NSNumber *> *newValues = _kkReadParamForDesc(getAPI, desc, now);

  // Mirror the slider value into pathData immediately. Otherwise a
  // subsequent segment-click reads a stale path value for its write-back
  // step (drawOSC's slider→pathData sync hasn't ticked yet) and clobbers
  // the segment we just edited.
  NSMutableArray<KKBezierPath *> *paths = _kkReadPaths(getAPI);
  KKBezierPath *p = _kkPathByLayerID(paths, selID);
  if (p && !_kkValuesEqual(desc.readPath(p), newValues)) {
    desc.writePath(p, newValues);
    _kkWritePaths(setAPI, paths);
  }

  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  NSMutableArray<KKTimingLane *> *lanes =
      json.length ? [[KKTimingLane lanesFromJSON:json] mutableCopy] : nil;
  if (!lanes.count) {
    [actAPI endAction:self];
    return;
  }
  BOOL changed = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKTimingLane *lane = lanes[i];
    if (![lane.propertyLabel isEqualToString:desc.label] ||
        ![lane.groupKey isEqualToString:selID])
      continue;
    NSInteger selSeg = lane.selectedSegment;
    if (selSeg < 0 || (NSUInteger)selSeg >= lane.segments.count)
      break;
    KKTimingSegment *seg = lane.segments[selSeg];
    if (_kkValuesEqual(seg.values, newValues))
      break;
    KKTimingLane *m = [lane copy];
    NSMutableArray<KKTimingSegment *> *segs = [m.segments mutableCopy];
    KKTimingSegment *mSeg = [seg copy];
    mSeg.values = newValues;
    segs[selSeg] = mSeg;
    m.segments = segs;
    lanes[i] = m;
    changed = YES;
    break;
  }
  if (changed) {
    KKApplyHTHNormalizationInPlace(lanes);
    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
  }
  [actAPI endAction:self];
}

@end
#pragma clang diagnostic pop
