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
/// position handle, box, slider, …), so a new OSC shape is a new strategy, not
/// new infrastructure.
///
/// The value is opaque (`id`): a scalar control boxes an NSNumber, a 2D control
/// (a position handle) boxes an NSValue point. The strategy owns the
/// dimension-specific comparisons (`valueOnTarget`, `snapValue`); the segment
/// stays value-agnostic.
@interface KKOSCGuideStrategy : NSObject

/// Pair the press point with the handle's live canvas position so the drag
/// maps correctly (typically forwards to -[KKOSCGuideBridge
/// reanchorAtScreen:handleCanvasPos:] with the plugin's handle position).
@property(nonatomic, copy) void (^captureAnchorAtScreen)(NSPoint screenPt);

/// Map a screen point to the control's value (boxed) using the control's own
/// geometry, so the drag tracks the cursor 1:1 like a native OSC drag.
@property(nonatomic, copy) id (^valueForScreenPoint)(NSPoint screenPt);

/// The control's current value, boxed (used to seed the drag start).
@property(nonatomic, copy) id (^currentValue)(void);

/// Push the value into the live OSC only (no timeline mutation). Called at
/// press so the handle holds while the gesture begins.
@property(nonatomic, copy) void (^setLiveValue)(id value);

/// Commit the value: live OSC + timeline + host notification. Called on each
/// drag move.
@property(nonatomic, copy) void (^applyValue)(id value);

/// YES if `value` is on the glowing target within the strategy's own
/// tolerance. The segment uses this both to snap during the drag (via
/// `snapValue`) and to gate the release.
@property(nonatomic, copy) BOOL (^valueOnTarget)(id value);

/// Return `value` snapped to the target when it is within tolerance, else
/// `value` unchanged. Optional; nil = no snapping.
@property(nonatomic, copy, nullable) id (^snapValue)(id value);

/// The cursor the real OSC would show at `screenPt` (e.g. the ring's
/// angle-based resize cursor), so the guide can present it through the
/// pass-through overlay - FCP's own imperative setCursor doesn't survive while
/// the guide panel is frontmost. Optional; nil = leave the cursor untouched.
@property(nonatomic, copy, nullable) NSCursor *_Nullable (^cursorForScreenPoint)
    (NSPoint screenPt);

/// Force the viewer OSC to redraw (so a hover-emphasis change shows). FCP only
/// re-runs drawOSC on a param change while the guide panel is frontmost, so the
/// segment calls this when the bridge's `handleHovered` flips. Typically
/// forwards to the inspector's preview-render nudge. Optional.
@property(nonatomic, copy, nullable) void (^requestRedraw)(void);

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
