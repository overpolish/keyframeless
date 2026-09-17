/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
@import PoseLanes;

// Magic Move's preference store: the factory values, the validation and the
// suite name. PoseLanes reads and writes through this adapter and knows none
// of it.
id<KFDefaults> MMDefaults(void);

/// On-screen control visibility has no explicit default setting: a new effect
/// starts from whatever was toggled last, so toggling writes the preference.
BOOL MMReadOSCVisibilityDefault(UInt32 parameter);
BOOL MMSaveOSCVisibilityDefault(UInt32 parameter, BOOL visible);
/// Whether a parameter is one of the on-screen control visibility toggles, so
/// callers can persist the preference without repeating the list.
BOOL MMIsOSCVisibilityParameter(UInt32 parameter);
