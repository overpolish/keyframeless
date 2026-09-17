/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFTimingEditor+Refresh.h"
#import "KFTimingEditor_Private.h"
#import "KFPropertyLane.h"

static NSString *KFTimingPropertyName(UInt32 parameter) {
  return KFPropertyDisplayName(parameter) ?: KFPropertyLanes().firstObject.displayName;
}
// Render callbacks recreate arrays and pose objects even when no key changed.
// Compare the values used by the evaluator, not snapshot object identity.
static BOOL KFGraphEntriesEqual(NSArray *a, NSArray *b) {
  if (a == b)
    return YES;
  if (!a || !b || a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (![a[i][@"time"] isEqual:b[i][@"time"]] ||
        ![a[i][@"pose"] isEqual:b[i][@"pose"]])
      return NO;
  return YES;
}
static void KFEnable(NSControl *control, BOOL enabled) {
  if (control.enabled != enabled)
    control.enabled = enabled;
}
static void KFText(NSTextField *field, NSString *text) {
  if (![field.stringValue isEqualToString:text])
    field.stringValue = text;
}
static void KFNumber(NSTextField *field, double value) {
  if (!field.objectValue || field.doubleValue != value)
    field.doubleValue = value;
}
static void KFSelect(NSPopUpButton *menu, NSInteger index) {
  if (menu.indexOfSelectedItem != index)
    [menu selectItemAtIndex:index];
}

@implementation KFTimingEditor (Refresh)
- (void)setEditorsEnabled:(BOOL)enabled {
  KFEnable(self.available, enabled);
  KFEnable(self.easingMenu, enabled);
  KFEnable(self.motionMenu, enabled);
  KFEnable(self.seedButton, enabled);
  for (ICInspectorRow *row in @[ self.durationRow, self.motionRow ])
    row.enabled = enabled;
  self.easingLabel.textColor = enabled ? ICInspectorTokens.labelColor : ICInspectorTokens.disabledTextColor;
  self.motionLabel.textColor = enabled ? ICInspectorTokens.labelColor : ICInspectorTokens.disabledTextColor;
}
- (void)updateControlsForGap:(KFInspectorGap *)gap editing:(BOOL)editing {
  KFText(self.motionLabel,[NSString stringWithFormat:@"%@ Added Motion",KFTimingPropertyName(self.displayedParameter)]);
  KFText(
      self.gapLabel,
      gap ? [NSString stringWithFormat:@"%@s → %@s",
                 [self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(gap.sourceTime))],
                 [self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(gap.destinationTime))]]
          : @"No keyframe gap here");
  if (!gap) {
    [self setEditorsEnabled:NO];
    return;
  }
  if (editing)
    return;
  KFPoseTiming *incoming = [gap.destinationPose timing],
               *outgoing = [gap.sourcePose timing];
  KFEnable(self.available, YES);
  KFEnable(self.easingMenu, YES);
  KFEnable(self.motionMenu, YES);
  KFEnable(self.seedButton, [gap.sourcePose addedMotion]!=MTAddedMotionNone);
  self.durationRow.enabled = !incoming.available;
  self.motionLabel.textColor = ICInspectorTokens.labelColor;
  self.easingLabel.textColor = ICInspectorTokens.labelColor;
  KFNumber(self.durationRow.fields[0], incoming.duration);
  NSControlStateValue available =
      incoming.available ? NSControlStateValueOn : NSControlStateValueOff;
  if (self.available.state != available)
    self.available.state = available;
  self.available.contentTintColor=incoming.available ? ICInspectorTokens.accentMatchingHost : ICInspectorTokens.decorationColor;
  NSString *tip = [NSString
      stringWithFormat:@"Into keyframe %lu. Limited to the available %.2f s.",
                       (unsigned long)gap.destinationIndex + 1,
                       CMTimeGetSeconds(CMTimeSubtract(gap.destinationTime,
                                                       gap.sourceTime))];
  if (![self.durationRow.fields[0].toolTip isEqualToString:tip])
    self.durationRow.fields[0].toolTip = tip;
  KFSelect(self.easingMenu, [gap.destinationPose easing]);
  NSInteger motion = [gap.sourcePose addedMotion];
  KFSelect(self.motionMenu, motion);
  KFNumber(self.motionRow.fields[0], outgoing.amount * 100);
  KFNumber(self.motionRow.fields[1], outgoing.speed);
  self.motionRow.enabled = motion != MTAddedMotionNone;
}
- (void)scrubGraphToFraction:(double)fraction {
  if (!self.window || self.hiddenOrHasHiddenAncestor || !self.plottedGaps.count || !isfinite(fraction)) return;
  CMTime start=KFInspectorGraphStart(self.plottedGaps);
  CMTime end=self.plottedGaps.firstObject.destinationTime;
  if (!CMTIME_IS_NUMERIC(start) || !CMTIME_IS_NUMERIC(end) || CMTimeCompare(end,start)<=0) return;
  fraction=fmax(0,fmin(1,fraction));
  CMTime target=fraction==0 ? start : fraction==1 ? end :
      CMTimeAdd(start,CMTimeMultiplyByFloat64(CMTimeSubtract(end,start),fraction));
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:self];
  @try {
    id<FxCommandAPI_v2> command=[self.manager apiForProtocol:@protocol(FxCommandAPI_v2)];
    if (!command) return;
    // Native key times already use the host clock.
    // FCP can return NO even when the seek succeeds.
    [command movePlayheadToTime:target error:nil];
    self.graph.progress=fraction;
  } @finally { [action endAction:self]; }
}
// Standalone refresh for direct callers; the clock uses the action-scoped body.
- (void)refresh {
  id<FxCustomParameterActionAPI_v4> action =
      [self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) {
    [self setEditorsEnabled:NO];
    return;
  }
  [action startAction:self];
  @try { [self refreshInspectorValuesInAction:action]; }
  @finally { [action endAction:self]; }
}
- (void)refreshInspectorValuesInAction:(id<FxCustomParameterActionAPI_v4>)action {
  if (!self.window || self.hiddenOrHasHiddenAncestor || self.writingSetting)
    return;
  // Native selection is provisional until its action finishes. Host snapshots
  // remain authoritative outside that interaction, including undo and scrubbing.
  BOOL editing = self.durationRow.interacting || self.motionRow.interacting ||
      self.easingMenu.interacting || self.motionMenu.interacting;
  UInt32 parameter =
      (editing || self.graph.scrubbing) ? self.displayedParameter
              : (self.plugin.activeInspectorParameterID ?: KFPropertyLanes().firstObject.parameterID);
  CMTime now = [action currentTime];
  KFInspectorGap *gap = KFReadInspectorGap(self.manager, parameter, now);
  NSArray<KFInspectorGap *> *graphGaps =
      self.graph.scrubbing ? self.plottedGaps : KFReadInspectorGraphGaps(self.manager,parameter,now);
  // The host action covers only reads. Publish controls/playhead before curve
  // work.
  self.displayedParameter = parameter;
  NSMutableArray *colors=[NSMutableArray new];
  for (KFInspectorGap *plotted in graphGaps)
    [colors addObjectsFromArray:KFPropertyLaneForParameter(plotted.parameterID).componentColors];
  self.graph.componentColors=graphGaps.count ? colors : KFPropertyLaneForParameter(parameter).componentColors;
  [self updateControlsForGap:gap editing:editing];
  CMTime graphStart=KFInspectorGraphStart(graphGaps);
  CMTime graphEnd=graphGaps.firstObject.destinationTime;
  if (!self.graph.scrubbing) self.graph.progress=graphGaps.count ? CMTimeGetSeconds(CMTimeSubtract(now,graphStart))/CMTimeGetSeconds(CMTimeSubtract(graphEnd,graphStart)) : 0;
  if (graphGaps.count)
    KFText(self.gapLabel,[NSString stringWithFormat:@"%@s → %@s",[self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(graphStart))],[self.gapTimeFormatter stringFromNumber:@(CMTimeGetSeconds(graphEnd))]]);
  CGSize size=self.plugin.inspectorImageSize;
  BOOL changed=self.plottedGaps.count!=graphGaps.count;
  for (NSUInteger i=0;!changed && i<graphGaps.count;i++) {
    KFInspectorGap *previous=self.plottedGaps[i], *next=graphGaps[i];
    changed=previous.parameterID!=next.parameterID || previous.destinationIndex!=next.destinationIndex ||
      !KFGraphEntriesEqual(previous.entries,next.entries);
  }
  if (changed || self.plottedParameter!=parameter || !CGSizeEqualToSize(self.plottedSize,size)) {
    self.plottedGaps=graphGaps;
    self.plottedParameter=parameter;
    self.plottedSize=size;
    self.graph.startFractions=graphGaps.count>1 ? KFInspectorGraphStartFractions(graphGaps) : @[];
    self.graph.points=KFInspectorCombinedGraphPoints(graphGaps,1024,size);
  }
  NSMutableSet *visible=[NSMutableSet new];
  if (self.graph.points.count>=2)
    for (KFInspectorGap *plotted in graphGaps) [visible addObject:@(plotted.parameterID)];
  [self publishGraphParameters:visible];
}
@end
