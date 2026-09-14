/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation

/// Outlives the Kai popover. Holds the standalone Kai helper's
/// update status so the popover can show an "update available" banner.
///
/// This package can't import KeyframelessKit (no dependency), so the host plugin
/// - which owns `KKUpdateChecker` - runs the actual check and pushes the result
/// in via `KKAIUpdate`. The popover fires `onCheckRequested` when it appears, so
/// the check runs whenever the user opens the AI panel.
@MainActor
public final class AIUpdateState: ObservableObject {
	public static let shared = AIUpdateState()

	/// A newer helper version, or nil when up to date / not installed.
	@Published public var availableVersion: String?
	/// Session-dismissed by the user (the banner's X). Reset never - a fresh
	/// process re-checks and re-shows.
	@Published public var dismissed: Bool = false
	/// The "What's New" / update page to open when the banner is tapped.
	public var notesURL: URL?

	/// Set by the host plugin: runs the KKUpdateChecker AI check. Fired from the
	/// popover's `onAppear`.
	public var onCheckRequested: (() -> Void)?

	private init() {}

	func requestCheck() { onCheckRequested?() }
}
