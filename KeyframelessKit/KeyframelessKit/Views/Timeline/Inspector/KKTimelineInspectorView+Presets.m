/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorView+Presets.h"
#import "KKTimelineInspectorView_Private.h"

#import "KKLocalized.h"
#import "KKPresetTimelineOps.h"
#import "KKPresetsPopover.h"
#import <KeyframelessKit/KKTimingCompat.h>

@interface KKTimelineInspectorView (PresetsInternal)
- (void)_applyPresetJSON:(NSString *)timelineJSON atPlayhead:(BOOL)atPlayhead;
@end

@implementation KKTimelineInspectorView (Presets)

// Falls back to 1.0 until the clip/frame duration is known.
- (double)_presetEndFraction {
  if (_clipDurationSeconds > 0.0 && _frameDurationSeconds > 0.0 &&
      _frameDurationSeconds < _clipDurationSeconds)
    return (_clipDurationSeconds - _frameDurationSeconds) /
           _clipDurationSeconds;
  return 1.0;
}

- (void)_buildPresetsRow {
  KKCheckboxView *unused = nil;
  _presetsRow = [self
      _buildTickGearRowWithParameterID:0
                            iconSymbol:@"bookmark"
                                 title:KKLoc(@"Presets",
                                             @"Section title: saved animation "
                                             @"presets.")
                     gearAccessibility:KKLoc(@"Preset library",
                                             @"Accessibility: open the saved "
                                             @"animation preset library.")
                            gearAction:@selector(_presetsClicked:)
                          showCheckbox:NO
                              checkbox:&unused
                            gearButton:&_presetsButton];
  [self addSubview:_presetsRow];
}

- (void)_presetsClicked:(id)sender {
  KKPresetsPopover *popover = _presetsPopover;
  if (!popover) {
    popover = [[KKPresetsPopover alloc] init];
    _presetsPopover = popover;
    __weak typeof(self) weak = self;
    popover.currentTimelineJSON = ^NSString *_Nullable {
      KKTimelineInspectorView *strong = weak;
      KKTimeline *timeline = strong.basicLanesView.currentTimeline;
      if (!timeline)
        return nil;
      // Fix the moving gaps to seconds so the preset keeps its transition feel.
      timeline =
          KKPresetTimelineAutoLocked(timeline, strong->_clipDurationSeconds);
      return [KKTimeline jsonFromTimeline:timeline];
    };
    popover.onApplyPreset = ^(NSString *timelineJSON, BOOL atPlayhead) {
      KKTimelineInspectorView *strong = weak;
      if (!strong)
        return;
      [strong _applyPresetJSON:timelineJSON atPlayhead:atPlayhead];
    };
  }
  popover.pluginKey = self.presetPluginKey;
  [popover showRelativeToRect:_presetsButton.bounds ofView:_presetsButton];
}

- (void)_applyPresetJSON:(NSString *)timelineJSON atPlayhead:(BOOL)atPlayhead {
  KKTimeline *preset = [KKTimeline timelineFromJSON:timelineJSON];
  if (!preset)
    return;
  double end = [self _presetEndFraction];
  double clip = _clipDurationSeconds;
  KKTimeline *result;
  if (atPlayhead) {
    // Merge the preset in starting at the playhead, keeping earlier keyposes -
    // lets you stack e.g. a pop-in then a later pop-out.
    double p = self.basicLanesView.playheadFraction;
    p = fmax(0.0, fmin(p, end));
    result = KKPresetTimelineMergedAtFraction(
        preset, self.basicLanesView.currentTimeline, p, end, clip);
  } else {
    // Override: fit the preset to the clip's reachable range [0, end].
    result = KKPresetTimelineRemapped(preset, 0.0, end, clip);
  }
  if (!result)
    return;
  // Persist + undo via the host's existing write path, then refresh the UI
  // immediately (the same two-step the AI merge apply uses).
  if (self.onTimelineMutated)
    self.onTimelineMutated(result);
  [self applyTimeline:result];
  // A multi-lane / structurally-rich preset may not fit Basic; jump to Advanced
  // so the user sees the real animation rather than a degraded Basic
  // projection.
  if (_selectedTab == KKTimelineTabBasic &&
      !KKTimelineIsBasicCompatible(result, end))
    [self setActiveTab:KKTimelineTabAdvanced];
}

@end
