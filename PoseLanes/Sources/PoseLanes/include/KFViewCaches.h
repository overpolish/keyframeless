/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFPropertyLane.h"
#import "KFEffect.h"
#import "KFHostSettings.h"
#import "KFPropertyMenu.h"

// Inspector view caches and the deferred native-key work an effect owes its
// lanes. One set of caches per effect instance, published once: the token
// identifies the cache, not the row, so rebuilding a row must not repeat the
// host write. Motion rebuilds every row several times per selection and holds
// more than one generation at a time, so a per-row write cost tens of
// milliseconds each time.
@interface KFEffect (KFViewCaches)
// Idempotent; a no-op until the host exposes its setting API.
- (void)publishViewCaches;
- (nullable KFPropertyPoseCache *)sharedCacheForLane:(nonnull KFPropertyLane *)lane;
// A native keyframe drag ends without a host callback, so observed linked
// moves are applied from a main-run-loop tick once the mouse is up.
- (void)startNativeLinkCommits;
@end
