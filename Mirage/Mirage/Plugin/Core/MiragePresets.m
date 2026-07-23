/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MiragePresets.h"

#import "Constants.h" // MirageCustomDefaultShaderSource
#import <KeyframelessKit/KKPresets.h>
#import <KeyframelessKit/KKTimeline.h> // KKTimeline / KKLane / KKKeyPose

// Plasma's directive lanes are keyed by their GLSL uniform name (uCenter is the
// point, uScale the scalar), not their display name - the same identity the
// renderer reads values by. See [[project_shader_guide_seed]].
static NSString *const kMiragePresetCenter = @"uCenter";
static NSString *const kMiragePresetScale = @"uScale";

// The @"Mirage" code lane carrying the plasma source. Non-animatable; the
// shader look lives here, so every preset includes it (applying a preset
// installs the plasma shader as well as its Center/Scale values).
static KKLane *MiragePresetCodeLane(void) {
  KKLane *lane = [KKLane laneWithLabel:kMirageCodeLaneLabel];
  lane.valueType = KKLaneValueTypeCode;
  lane.codeString = MirageCustomDefaultShaderSource();
  lane.animatable = NO;
  lane.enabled = NO;
  return lane;
}

// A constant directive lane (one keypose at t=0). `values` has one element for
// a scalar (uScale), two for a point (uCenter).
static KKLane *MiragePresetConstLane(NSString *uniform,
                                     NSArray<NSNumber *> *values) {
  KKLane *lane = [KKLane laneWithLabel:uniform];
  lane.valueType = KKLaneValueTypeFloat;
  lane.enabled = NO; // constant
  lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
  return lane;
}

// An animated directive lane: start -> end over the whole clip.
static KKLane *MiragePresetAnimLane(NSString *uniform,
                                    NSArray<NSNumber *> *start,
                                    NSArray<NSNumber *> *end) {
  KKLane *lane = [KKLane laneWithLabel:uniform];
  lane.valueType = KKLaneValueTypeFloat;
  lane.enabled = YES; // animated
  lane.keyposes = @[
    [KKKeyPose keyposeAtTime:0.0 values:start],
    [KKKeyPose keyposeAtTime:1.0 values:end],
  ];
  return lane;
}

static KKPreset *MirageMakePreset(NSString *identifier, NSString *name,
                                  NSArray<KKLane *> *lanes) {
  KKTimeline *tl = [KKTimeline timeline];
  tl.lanes = lanes;
  KKPreset *pr = [[KKPreset alloc] init];
  pr.identifier = identifier;
  pr.name = name; // KKLocalizable key for built-ins (falls back to itself)
  pr.timelineJSON = [KKTimeline jsonFromTimeline:tl] ?: @"";
  pr.builtin = YES;
  return pr;
}

NSArray<KKPreset *> *MirageBuiltinPresets(void) {
  // One built-in: plasma with the Center panning left -> right across the
  // frame, so the shared Presets popover (and its guide) always has a real
  // animation to apply.
  return @[
    MirageMakePreset(@"shader.plasmaDrift", @"Plasma Drift",
                     @[
                       MiragePresetCodeLane(),
                       MiragePresetAnimLane(kMiragePresetCenter,
                                            @[ @0.25, @0.5 ], @[ @0.75, @0.5 ]),
                       MiragePresetConstLane(kMiragePresetScale, @[ @4.0 ])
                     ]),
  ];
}
