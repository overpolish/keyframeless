/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import SwiftUI

/// ObjC-callable factory that builds an `NSHostingView` wrapping the SwiftUI
/// `AIButton`. FxPlug plugin banners (Rounded, Canvas, etc.) use this to
/// reuse the workflow-ext button design without pulling SwiftUI into
/// KeyframelessKit.
@objc(KKAIBannerHost)
public final class AIBannerHost: NSObject {
	@MainActor
	@objc public static func makeButton(
		productContext: String,
		onRun: @escaping (String) -> Void
	) -> NSView {
		let button = AIButton(
			selectedCount: 0,
			productContext: productContext,
			onRun: onRun
		)
		let host = NSHostingView(rootView: button)
		host.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			host.widthAnchor.constraint(equalToConstant: 22),
			host.heightAnchor.constraint(equalToConstant: 22),
		])
		return host
	}
}
