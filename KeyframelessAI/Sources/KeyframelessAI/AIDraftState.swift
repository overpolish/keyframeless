/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation

/// Outlives the AI popover. Holds the in-progress prompt, any pending answer,
/// and the routing state so that closing the popover (or it being dismissed
/// by clicking elsewhere) doesn't lose the user's typing or interrupt an
/// in-flight request.
@MainActor
public final class AIDraftState: ObservableObject {
	public static let shared = AIDraftState()

	@Published public var prompt: String = ""
	@Published public var pendingAnswer: String?
	@Published public var isRouting: Bool = false
	@Published public var routingError: String?

	private init() {}

	public func reset() {
		prompt = ""
		pendingAnswer = nil
		routingError = nil
	}
}
