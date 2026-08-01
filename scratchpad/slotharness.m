/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Drives the lane catalog's `#slots` stamping end to end against a real
// KKTimeline: defaults on first sight, add, remove-from-the-middle.
//
// Built by scratchpad/run-slotharness.sh, which links the KeyframelessKit
// framework Xcode already produced. The catalog's own entry point is not called
// here - it hangs the GLSL validator and the autocomplete off a lane, which
// would pull the whole transpiler into a harness that has nothing to say about
// either. What it calls instead is exactly the chain that entry point runs:
// build the prototype lanes from the directives, then stamp.

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KeyframelessKit.h>

#import "MirageLaneCatalog.h"

static int gFailures = 0;

static void Check(BOOL condition, NSString *what) {
  printf("%s  %s\n", condition ? "ok  " : "FAIL", what.UTF8String);
  if (!condition)
    gFailures++;
}

static NSArray<KKLane *> *PrototypeLanes(NSString *source) {
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  MirageAppendScalarLanes(lanes, source);
  MirageAppendColorLanes(lanes, source);
  return lanes;
}

static NSArray<KKLane *> *StampedLanes(NSString *source, KKTimeline *timeline) {
  NSMutableArray<KKLane *> *lanes = [PrototypeLanes(source) mutableCopy];
  MirageStampSlotLanes(lanes, source, timeline);
  return lanes;
}

static NSArray<NSString *> *KeysOf(NSArray<KKLane *> *lanes) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (KKLane *lane in lanes)
    [out addObject:lane.key ?: @""];
  return out;
}

static NSArray<NSString *> *LabelsOf(NSArray<KKLane *> *lanes) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (KKLane *lane in lanes)
    [out addObject:lane.label ?: @""];
  return out;
}

static NSString *SlotSource(void) {
  return @"// #template generator\n"
         @"// #color-surface ring=hue\n"
         @"// #float label=\"Master\" min=0 max=1 default=0.5\n"
         @"uniform float uMaster;\n"
         @"// #slots name=\"Colour\" max=8 default=2 min=1\n"
         @"// #color label=\"New Colour {n}\" puck={\"Colour {n}\", "
         @"\"{n}.circle\"} pick=hue surface=\"a:+180\"\n"
         @"uniform vec4 uNewColour;\n"
         @"// #float label=\"Strength {n}\" min=0 max=1 default=0.5\n"
         @"uniform float uNewStrength;\n"
         @"// #float label=\"Bias {n}\" min=0 max=1 default=0.25\n"
         @"uniform float uNewBias;\n"
         @"// #slots-end\n"
         @"void mainImage(out vec4 O, in vec2 fc) { O = vec4(0.0); }\n";
}

int main(void) {
  @autoreleasepool {
    NSString *source = SlotSource();

    // Prototypes: what a build with no timeline in hand produces, which is what
    // the validator and the autocomplete ask for.
    NSArray<KKLane *> *protos = PrototypeLanes(source);
    printf("\nprototypes: %s\n", KeysOf(protos).description.UTF8String);
    Check([KeysOf(protos) containsObject:@"uNewColour"] &&
              [KeysOf(protos) containsObject:@"uNewStrength"],
          @"a prototype is keyed by its uniform, {n} left in the label");
    NSMutableArray<KKLane *> *unstamped = [protos mutableCopy];
    MirageStampSlotLanes(unstamped, source, nil);
    Check([KeysOf(unstamped) isEqualToArray:KeysOf(protos)],
          @"no timeline, no stamping - the prototypes stand");

    // First sight: a timeline with no registry gets the declared default=2.
    KKTimeline *timeline = [KKTimeline timeline];
    NSArray<KKLane *> *lanes = StampedLanes(source, timeline);
    NSArray<NSString *> *ids = KKTimelineSlotInstanceIDs(timeline, @"Colour");
    printf("after first build: %s\n", KeysOf(lanes).description.UTF8String);
    printf("labels:            %s\n", LabelsOf(lanes).description.UTF8String);
    Check(ids.count == 2, @"a legacy timeline is brought up to default=2");
    Check(![KeysOf(lanes) containsObject:@"uNewColour"],
          @"and the prototype itself is not a lane");
    NSString *firstKey = KKSlotLaneKey(@"Colour", ids[0], @"uNewColour");
    NSString *secondKey = KKSlotLaneKey(@"Colour", ids[1], @"uNewColour");
    Check([KeysOf(lanes) containsObject:firstKey] &&
              [KeysOf(lanes) containsObject:secondKey],
          @"one lane set per instance, keyed <group>#<id>.<uniform>");
    Check([LabelsOf(lanes) containsObject:@"New Colour 1"] &&
              [LabelsOf(lanes) containsObject:@"New Colour 2"] &&
              [LabelsOf(lanes) containsObject:@"Strength 2"],
          @"labels are rendered at the instance's display number");
    // Instance-major, WITHIN the inspector group: the two sliders of instance 1
    // sit together, ahead of instance 2's. The colour of the same instance is
    // elsewhere on purpose - it belongs to the Colours group, which the build's
    // ordering pass keeps separate.
    NSUInteger firstStrength = [KeysOf(lanes)
        indexOfObject:KKSlotLaneKey(@"Colour", ids[0], @"uNewStrength")];
    NSUInteger firstBias = [KeysOf(lanes)
        indexOfObject:KKSlotLaneKey(@"Colour", ids[0], @"uNewBias")];
    NSUInteger secondStrength = [KeysOf(lanes)
        indexOfObject:KKSlotLaneKey(@"Colour", ids[1], @"uNewStrength")];
    NSUInteger secondBias = [KeysOf(lanes)
        indexOfObject:KKSlotLaneKey(@"Colour", ids[1], @"uNewBias")];
    Check(MAX(firstStrength, firstBias) < MIN(secondStrength, secondBias),
          @"instance-major: every control of one, then the next");
    NSUInteger paletteRow = [KeysOf(lanes) indexOfObject:@"Palette"];
    Check(paletteRow < [KeysOf(lanes) indexOfObject:firstKey],
          @"a colour instance still lands under its palette bar");
    Check([KeysOf(StampedLanes(source, timeline)) isEqualToArray:KeysOf(lanes)],
          @"a second build over a registered group mints nothing new");

    // Add: the lane set grows and every existing key is untouched.
    NSString *added = KKTimelineStampSlotInstance(timeline, @"Colour", protos);
    NSArray<KKLane *> *grown = StampedLanes(source, timeline);
    printf("after add:         %s\n", KeysOf(grown).description.UTF8String);
    Check(KKTimelineSlotInstanceIDs(timeline, @"Colour").count == 3,
          @"adding registers a third instance");
    Check([KeysOf(grown) containsObject:firstKey] &&
              [KeysOf(grown) containsObject:secondKey],
          @"the keys that were there are the keys that are there");
    Check([KeysOf(grown)
              containsObject:KKSlotLaneKey(@"Colour", added, @"uNewColour")] &&
              [LabelsOf(grown) containsObject:@"New Colour 3"],
          @"and the new one lands last, numbered 3");

    // Remove the MIDDLE one: the survivors keep their keys and their keyframes,
    // and only their numbers move.
    KKLane *marked = nil;
    for (KKLane *lane in grown)
      if ([lane.key isEqualToString:secondKey])
        marked = lane;
    Check(marked.keyposes.count > 0,
          @"the middle instance carries the prototype's default keypose");
    KKTimelineRemoveSlotInstance(
        timeline, @"Colour", KKTimelineSlotInstanceIDs(timeline, @"Colour")[1]);
    NSArray<KKLane *> *survivors = StampedLanes(source, timeline);
    printf("after remove:      %s\n", KeysOf(survivors).description.UTF8String);
    printf("labels:            %s\n",
           LabelsOf(survivors).description.UTF8String);
    Check(KKTimelineSlotInstanceIDs(timeline, @"Colour").count == 2,
          @"removing the middle instance leaves two");
    Check([KeysOf(survivors) containsObject:firstKey] &&
              [KeysOf(survivors) containsObject:KKSlotLaneKey(@"Colour", added,
                                                              @"uNewColour")],
          @"the first and the third survive under their own keys");
    Check(![KeysOf(survivors) containsObject:secondKey],
          @"and the one that was removed is gone");
    Check([LabelsOf(survivors) containsObject:@"New Colour 1"] &&
              [LabelsOf(survivors) containsObject:@"New Colour 2"] &&
              ![LabelsOf(survivors) containsObject:@"New Colour 3"],
          @"the survivor is renumbered for display, not re-keyed");

    // The shape of every shader written before this existed.
    NSString *legacy = @"// #template filter\n"
                       @"// #float label=\"Amount\" min=0 max=2 default=0.5\n"
                       @"uniform float uAmount;\n"
                       @"// #color label=\"Tint\"\n"
                       @"uniform vec4 uTint;\n";
    NSArray<KKLane *> *before = PrototypeLanes(legacy);
    NSArray<KKLane *> *after = StampedLanes(legacy, [KKTimeline timeline]);
    Check([KeysOf(before) isEqualToArray:KeysOf(after)] &&
              [LabelsOf(before) isEqualToArray:LabelsOf(after)],
          @"a shader with no #slots builds the identical lane set");
  }
  printf("\n%s\n", gFailures ? "HARNESS FAILED" : "harness clean");
  return gFailures ? 1 : 0;
}
