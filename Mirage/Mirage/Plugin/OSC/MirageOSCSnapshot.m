/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageOSCSnapshot.h"

void MirageSetTimelineSnapshot(KKTimeline *timeline) {
  KKSetProcessTimelineSnapshot(timeline);
}

void MirageSetFrameDurationSeconds(double frameDurSec) {
  KKSetProcessFrameDurationSeconds(frameDurSec);
}
