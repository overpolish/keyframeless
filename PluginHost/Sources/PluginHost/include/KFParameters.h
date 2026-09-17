/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>

// Registration shapes every plugin repeats: a hidden saved setting, the
// scratch value that asks for a repaint, a transient cache token and a
// full-width custom view.
BOOL KFAddHiddenToggle(id<FxParameterCreationAPI_v5> api, NSString *name, UInt32 parameterID,
                       BOOL defaultValue);
// Saved on purpose: DONT_SAVE writes propagate late in the host, and a
// non-animatable saved value is what invalidates its cached frame.
BOOL KFAddHostRefreshToken(id<FxParameterCreationAPI_v5> api, NSString *name, UInt32 parameterID);
// Transient: the token identifies a disposable in-process snapshot, so it must
// never reach a saved document.
BOOL KFAddCacheToken(id<FxParameterCreationAPI_v5> api, NSString *name, UInt32 parameterID);
// A keyframed custom parameter drawn by the plugin's own row.
BOOL KFAddCustomUIParameter(id<FxParameterCreationAPI_v5> api, UInt32 parameterID, id defaultValue);
// A custom view with no keyframed value, such as a header or editor panel.
BOOL KFAddCustomUIPanel(id<FxParameterCreationAPI_v5> api, UInt32 parameterID);
