/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation

/// Per-product activation state for SwiftUI. The inspector ViewBridge process
/// is shared across plugin instances, so states are kept in a per-product
/// registry rather than a single shared singleton.
@MainActor
public final class LicenseState: ObservableObject {
	private static var states: [String: LicenseState] = [:]

	public static func shared(for productID: String) -> LicenseState {
		if let existing = states[productID] { return existing }
		let state = LicenseState(productID: productID)
		states[productID] = state
		return state
	}

	public let productID: String
	@Published public private(set) var record: LicenseRecord?

	public var isActivated: Bool { record != nil }

	private init(productID: String) {
		self.productID = productID
		record = LicenseManager.record(for: productID)
	}

	public func refresh() {
		record = LicenseManager.record(for: productID)
	}

	public func activate(licenseKey: String) async throws {
		record = try await LicenseManager.activate(
			licenseKey: licenseKey, productID: productID)
	}
}
