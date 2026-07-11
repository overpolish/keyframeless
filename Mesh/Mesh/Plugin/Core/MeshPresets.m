/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MeshPresets.h"
#import "MeshColorSpace.h"  // MeshColorLabel, KK_MESH_COLOR_COUNT_LABEL
#import "MeshLaneCatalog.h" // MeshBuildAvailableLanes
#import <KeyframelessKit/KKPresets.h>
#import <KeyframelessKit/KKTimingStage.h>

// One built-in look: a Type index plus a curated sRGB palette. Every other lane
// is left at its Mesh default (unlisted lanes don't merge). Colours are 0..1
// sRGB, alpha is always 1. Palettes are taken verbatim from
// paper-design/shaders' Warp / Dithering presets, mapped onto the Type each
// suits best.
typedef struct {
  const char *identifier; // stable UUID (never changes once shipped)
  const char *name;       // English display + KKLocalizable key
  int type;               // Mesh Type index (0..11)
  int colorCount;         // 2..cap for the Type
  float colors[KK_MESH_COLOR_MAX][3];
} MeshPresetSpec;

static const MeshPresetSpec kMeshPresets[] = {
    // Mesh, meadow green into deep night (#a7e58b #324472 #0a180d).
    {"7C2A1E90-1B4D-4E21-9F30-0A1B2C3D0002",
     "Meadow",
     0,
     3,
     {{0.654902f, 0.898039f, 0.545098f},
      {0.196078f, 0.266667f, 0.447059f},
      {0.039216f, 0.094118f, 0.050980f}}},
    // Silk, charcoal to porcelain (#111314 #9faeab #f3fee7 #f3fee7).
    {"7C2A1E90-1B4D-4E21-9F30-0A1B2C3D0003",
     "Porcelain",
     10,
     4,
     {{0.066667f, 0.074510f, 0.078431f},
      {0.623529f, 0.682353f, 0.670588f},
      {0.952941f, 0.996078f, 0.905882f},
      {0.952941f, 0.996078f, 0.905882f}}},
    // Grainy, smouldering ember (#3b1515 #954751 #ffc085).
    {"7C2A1E90-1B4D-4E21-9F30-0A1B2C3D0005",
     "Ember",
     2,
     3,
     {{0.231373f, 0.082353f, 0.082353f},
      {0.584314f, 0.278431f, 0.317647f},
      {1.0f, 0.752941f, 0.521569f}}},
};

// Find a catalog lane by label (the catalog carries the canonical value type /
// units / bounds each preset lane must keep).
static KKLane *MeshCatalogLane(NSArray<KKLane *> *catalog, NSString *label) {
  for (KKLane *l in catalog)
    if ([l.label isEqualToString:label])
      return l;
  return nil;
}

// A copy of the catalog lane holding a single keypose - a CONSTANT value, not
// an animated lane. These are "look" presets, not animations: `enabled = NO`
// keeps each param a plain constant (Type especially is non-animatable, and an
// animated Type reads as unset so its per-type lanes all show). The Override
// apply (KKPresetTimelineRemapped) copies constant lanes through regardless of
// `enabled`, so they still apply.
static KKLane *MeshPresetConstLane(NSArray<KKLane *> *catalog, NSString *label,
                                   NSArray<NSNumber *> *values) {
  KKLane *src = MeshCatalogLane(catalog, label);
  if (!src)
    return nil;
  KKLane *lane = [src copy];
  lane.enabled = NO;
  lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
  return lane;
}

NSArray<KKPreset *> *MeshBuiltinPresets(void) {
  NSArray<KKLane *> *catalog = MeshBuildAvailableLanes();
  NSMutableArray<KKPreset *> *out = [NSMutableArray array];
  const size_t count = sizeof(kMeshPresets) / sizeof(kMeshPresets[0]);
  for (size_t i = 0; i < count; i++) {
    const MeshPresetSpec *s = &kMeshPresets[i];
    NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
    KKLane *typeLane = MeshPresetConstLane(catalog, @"Type", @[ @(s->type) ]);
    if (typeLane)
      [lanes addObject:typeLane];
    KKLane *countLane = MeshPresetConstLane(catalog, KK_MESH_COLOR_COUNT_LABEL,
                                            @[ @(s->colorCount) ]);
    if (countLane)
      [lanes addObject:countLane];
    for (int c = 0; c < s->colorCount && c < KK_MESH_COLOR_MAX; c++) {
      NSArray<NSNumber *> *rgba =
          @[ @(s->colors[c][0]), @(s->colors[c][1]), @(s->colors[c][2]), @1.0 ];
      KKLane *colorLane = MeshPresetConstLane(catalog, MeshColorLabel(c), rgba);
      if (colorLane)
        [lanes addObject:colorLane];
    }

    KKTimeline *timeline = [KKTimeline timeline];
    timeline.lanes = lanes;
    NSString *json = [KKTimeline jsonFromTimeline:timeline];
    if (!json.length)
      continue;

    KKPreset *preset = [[KKPreset alloc] init];
    preset.identifier = [NSString stringWithUTF8String:s->identifier];
    preset.name = [NSString stringWithUTF8String:s->name];
    preset.timelineJSON = json;
    preset.builtin = YES;
    [out addObject:preset];
  }
  return out;
}
