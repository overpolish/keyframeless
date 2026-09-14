/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// ObjC-callable surface for `AIUpdateState`. The host plugin owns
/// `KKUpdateChecker` (this package can't import KeyframelessKit), so it
/// registers the check handler once and pushes the result when the check
/// returns. Mirrors `KKAIDraft`.
@objc(KKAIUpdate)
public final class AIUpdateBridge: NSObject {
	/// Register the closure the popover fires on appear. The host runs its
	/// `KKUpdateChecker` AI check inside it, then calls `setAvailableVersion:`.
	@MainActor
	@objc public static func setCheckHandler(_ handler: (() -> Void)?) {
		AIUpdateState.shared.onCheckRequested = handler
	}

	/// Push the check result. A nil / empty `version` clears the banner (up to
	/// date, or the helper isn't installed).
	@MainActor
	@objc public static func setAvailableVersion(
		_ version: String?, notesURL: String?
	) {
		let v = (version?.isEmpty == false) ? version : nil
		AIUpdateState.shared.availableVersion = v
		AIUpdateState.shared.notesURL = notesURL.flatMap { URL(string: $0) }
	}
}
