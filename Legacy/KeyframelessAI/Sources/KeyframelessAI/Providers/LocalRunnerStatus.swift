/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Indirection for the runner's coarse status updates ("Loading model…",
/// "Thinking…"). In-process the runner writes them straight to the client's
/// `AIDraftState`, so the inspector shows what's actually happening.
///
/// Out-of-process the runner executes inside the `kk-ai-helper` CHILD, whose
/// `AIDraftState` no UI observes - so the status would never reach the plugin and
/// it'd sit on the pipeline's generic "Reading prompt…". The helper fixes this by
/// installing a `sink` (via the task-local) around the runner call that forwards
/// each update to the client as a status frame; the client then writes ITS OWN
/// `AIDraftState`. Leave the sink nil for the default in-process behaviour.
public enum LocalRunnerStatus {
	/// When set, status goes here instead of `AIDraftState` (the helper forwards
	/// it over the socket). Task-local so it's scoped to one request and inherited
	/// by the runner's async work, including across its `MainActor` hops.
	@TaskLocal public static var sink: (@Sendable (String) -> Void)?

	/// Report a coarse status. Routes to the task-local sink when present (helper),
	/// else to the in-process `AIDraftState` on the main actor.
	public static func report(_ status: String) async {
		if let sink {
			sink(status)
		} else {
			await MainActor.run { AIDraftState.shared.routingStatus = status }
		}
	}
}
