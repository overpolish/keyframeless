/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
@import PoseLanes;

// Magic Move's lane definitions, in inspector order. They are registered with
// PoseLanes at load, so the rest of the plugin resolves a lane by parameter ID
// through `KFPropertyLaneForParameter`.
NSArray<KFPropertyLane *> *MMLanes(void);

// Named accessors for the callers that address one property directly, such as
// rendering and the viewer's controls.
KFPropertyLane *MMPositionLane(void);
KFPropertyLane *MMScaleLane(void);
KFPropertyLane *MMRotationLane(void);
KFPropertyLane *MMOpacityLane(void);
KFPropertyLane *MMBlurLane(void);
KFPropertyLane *MMAnchorLane(void);
