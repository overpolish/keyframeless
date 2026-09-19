/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>

// Structural keypose editing for the keypose map: one keypose added, deleted or
// retimed per call. Every read uses the disposable inspector cache and each
// call applies one preflighted snapshot per touched lane. Callers own the host
// action and the undo group, as they do for links and Match In/Out.

// The evaluated value at `time` becomes the new keypose, so the curve keeps its
// shape where it already had one, and creation defaults apply as they do to a
// key the host creates. Fails when the lane is already keyed there.
BOOL KFAddKeypose(id<PROAPIAccessing> manager, UInt32 parameter, CMTime time,
                  NSError **error);
// Fails on a lane's only keypose: emptying a lane is Reset Parameter's job, and
// it has to restore the default value rather than leave the lane unkeyed.
BOOL KFDeleteKeypose(id<PROAPIAccessing> manager, UInt32 parameter, CMTime time,
                     NSError **error);
// Linked partners travel to the same time, as they do for a native host drag.
BOOL KFMoveKeypose(id<PROAPIAccessing> manager, UInt32 parameter, CMTime from,
                   CMTime to, NSError **error);
