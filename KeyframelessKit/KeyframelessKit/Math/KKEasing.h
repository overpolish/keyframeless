/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, KKEasingCurve) {
  KKEasingCurveEaseIn = 0,
  KKEasingCurveEaseOut = 1,
  KKEasingCurveEaseInOut = 2,
  KKEasingCurveElastic = 3,
  KKEasingCurveBounce = 4,
};

static const NSInteger KKEasingCurveCount __attribute__((unused)) = 5;

double KKEaseInQuart(double t);
double KKEaseOutQuart(double t);
double KKEaseInOutQuart(double t);
double KKEaseOutElastic(double t);
double KKEaseOutBounce(double t);

/// Apply the given curve to a raw 0→1 factor.
double KKApplyEasing(double raw, KKEasingCurve curve);
