/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
@import OSCViewer;

// Magic Move's on-screen control: the box outline, scale handles, rotation
// rings and anchor square over the transformed image. It supplies the pose
// read, visibility parameters and lane writes; the control behaviour itself
// lives in OSCViewerControl.
@interface MagicMoveOSC : OSCViewerControl
@end
