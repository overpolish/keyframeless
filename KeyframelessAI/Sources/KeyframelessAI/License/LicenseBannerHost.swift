/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import SwiftUI

/// ObjC-callable factory that builds an `NSHostingView` wrapping the SwiftUI
/// `LicenseButton`, for the plugin logo banner. Mirrors `KKAIBannerHost` so
/// plugins add license activation the same way they add the AI button.
/// Returns nil once the product is activated - no trial button at all.
@objc(KKLicenseBannerHost)
public final class LicenseBannerHost: NSObject {
	/// `tintColor` colors the Trial label - pass `[NSColor accentMatchingHost]`
	/// so it sits with the host's inspector chrome. `onActivated` fires once
	/// after a successful activation - plugins use it to nudge a re-render so
	/// the cached watermarked frame refreshes without the user having to scrub.
	@MainActor
	@objc public static func makeButton(
		productID: String,
		productName: String,
		purchaseURL: String?,
		tintColor: NSColor?,
		onActivated: (() -> Void)?
	) -> NSView? {
		guard !LicenseManager.isActivated(productID) else { return nil }
		let button = LicenseButton(
			productID: productID,
			productName: productName,
			purchaseURL: purchaseURL.flatMap(URL.init(string:)),
			tint: tintColor.map(Color.init(nsColor:)) ?? .accentColor,
			onActivated: onActivated)
		let host = NSHostingView(rootView: button)
		host.translatesAutoresizingMaskIntoConstraints = false
		host.heightAnchor.constraint(equalToConstant: 22).isActive = true
		return host
	}
}
