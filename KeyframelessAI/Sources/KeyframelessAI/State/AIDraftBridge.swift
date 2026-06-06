/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// ObjC-callable surface for the shared `AIDraftState`. Plugin onRun handlers
/// use these to drive the popover's routing spinner, error banner, answer
/// card, and prompt field from outside Swift.
@objc(KKAIDraft)
public final class AIDraftBridge: NSObject {
	@MainActor
	@objc public static func setRouting(_ routing: Bool) {
		AIDraftState.shared.isRouting = routing
		if !routing { AIDraftState.shared.routingStatus = nil }
	}

	/// Mark a transform as applied. Lights the green "done" sparkle until the
	/// user next interacts. Call only on the mutation-applied path, not for
	/// answers or errors.
	@MainActor
	@objc public static func setCompleted(_ completed: Bool) {
		AIDraftState.shared.didCompleteMutation = completed
	}

	@MainActor
	@objc public static func setRoutingStatus(_ status: String?) {
		AIDraftState.shared.routingStatus = status
	}

	/// Set the pending answer. A non-nil answer also lights the green "done"
	/// sparkle (until the user next interacts), like an applied mutation does.
	@MainActor
	@objc public static func setAnswer(_ answer: String?) {
		AIDraftState.shared.pendingAnswer = answer
		AIDraftState.shared.didAnswerQuestion = (answer != nil)
	}

	@MainActor
	@objc public static func setError(_ message: String?) {
		AIDraftState.shared.routingError = message
	}

	@MainActor
	@objc public static func clearPrompt() {
		AIDraftState.shared.prompt = ""
	}
}
