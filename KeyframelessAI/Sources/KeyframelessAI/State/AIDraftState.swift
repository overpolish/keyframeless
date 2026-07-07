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
	/// Optional short label shown next to the spinner while routing
	/// ("Planning timing…", "Resolving values…"). Falls back to "Thinking…"
	/// when nil.
	@Published public var routingStatus: String?
	/// True once a transform (mutation) has been applied, until the user next
	/// interacts. Drives the green "done" sparkle so a fire-and-look-away run
	/// still has a confirmation waiting when the user looks back. Answers and
	/// errors do not set this - only an applied mutation does.
	@Published public var didCompleteMutation: Bool = false
	/// True once a question has been answered, until the user next interacts.
	/// Drives the same green "done" sparkle as `didCompleteMutation` so a
	/// fire-and-look-away question also leaves a badge waiting (plugins + the
	/// Steno workflow extension).
	@Published public var didAnswerQuestion: Bool = false
	/// How many local generations the shared kk-ai-helper is running right now
	/// (polled while routing on the local provider). Drives the popover's job
	/// indicator next to the Stop button; 0 hides it.
	@Published public var localJobCount: Int = 0
	/// Set when the user taps Stop, so the error the cancelled request reports
	/// back is swallowed (a deliberate cancel isn't a failure). Consumed by the
	/// next error, cleared when a new run starts.
	public var cancelRequested: Bool = false

	private init() {}

	public func reset() {
		prompt = ""
		pendingAnswer = nil
		routingError = nil
		routingStatus = nil
		didCompleteMutation = false
		didAnswerQuestion = false
	}
}
