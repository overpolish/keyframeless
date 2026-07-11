/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderOSCSnapshot.h"

void ShaderSetTimelineSnapshot(KKTimeline *timeline) {
  KKSetProcessTimelineSnapshot(timeline);
}

void ShaderSetFrameDurationSeconds(double frameDurSec) {
  KKSetProcessFrameDurationSeconds(frameDurSec);
}
