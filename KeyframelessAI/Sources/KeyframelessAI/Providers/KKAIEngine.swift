/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Presence of the shared local-inference engine ("Keyframeless AI"). The engine
/// ships as a SEPARATE install (a launchd-managed `kk-ai-helper` in
/// /Library/Application Support/Keyframeless) so the plugins stay small. When it's
/// absent, the on-device-models UI shows an install note instead of failing silently
/// the first time someone picks a local model.
public enum KKAIEngine {
	/// DEBUG/preview toggle: force the install note on regardless of actual state so
	/// the visual can be checked without uninstalling the engine. Ships as false - the
	/// note (and the Action tab gating) then follow `isInstalled`.
	public static let forceShowInstallNotice = false

	static let installedHelperPath = "/Library/Application Support/Keyframeless/kk-ai-helper"

	/// True when the engine has been installed on this Mac.
	public static var isInstalled: Bool {
		FileManager.default.fileExists(atPath: installedHelperPath)
	}

	/// Whether to surface the "Install Keyframeless AI" note in the local-models UI.
	public static var showInstallNotice: Bool {
		forceShowInstallNotice || !isInstalled
	}
}
