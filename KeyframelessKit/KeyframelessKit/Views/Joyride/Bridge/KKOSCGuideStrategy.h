/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The OSC-shape-specific half of an OSC guide, supplied as blocks (the same
/// block-based inversion of control used for inspector guides).
/// KKOSCGuideBridge handles the generic screen↔canvas affine; this maps a
/// screen drag to a value and back for one particular control (radius circle,
/// box, slider, …), so a new OSC shape is a new strategy, not new
/// infrastructure.
@interface KKOSCGuideStrategy : NSObject

/// Pair the press point with the handle's live canvas position so the drag
/// maps correctly (typically forwards to -[KKOSCGuideBridge
/// reanchorAtScreen:handleCanvasPos:] with the plugin's handle position).
@property(nonatomic, copy) void (^captureAnchorAtScreen)(NSPoint screenPt);

/// Map a screen point to the control's value using the control's own
/// geometry, so the drag tracks the cursor 1:1 like a native OSC drag.
@property(nonatomic, copy) double (^valueForScreenPoint)(NSPoint screenPt);

/// The control's current value (used to seed the drag start).
@property(nonatomic, copy) double (^currentValue)(void);

/// Push the value into the live OSC only (no timeline mutation). Called at
/// press so the handle holds while the gesture begins.
@property(nonatomic, copy) void (^setLiveValue)(double value);

/// Commit the value: live OSC + timeline + host notification. Called on each
/// drag move.
@property(nonatomic, copy) void (^applyValue)(double value);

/// The value the drag step nudges toward (the glowing target).
@property(nonatomic) double targetValue;
/// Snap/“landed on target” tolerance around targetValue.
@property(nonatomic) double snapTolerance;
/// When YES the drag step only advances once the value is on the target at
/// release; when NO any release advances.
@property(nonatomic) BOOL requireTargetHit;

/// KKMarkup tooltip text for the three visual steps (press, drag, done).
@property(nonatomic, copy) NSString *clickMessage;
@property(nonatomic, copy) NSString *dragMessage;
@property(nonatomic, copy) NSString *selectedMessage;

/// Spotlight rect for the final “…is available whenever selected” step
/// (e.g. the effect's FCP header). NSZeroRect → floating tip.
@property(nonatomic, copy, nullable) NSRect (^finalStepTargetRect)(void);

@end

NS_ASSUME_NONNULL_END
