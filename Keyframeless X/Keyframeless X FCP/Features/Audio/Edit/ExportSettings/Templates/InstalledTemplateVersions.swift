/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation
import KeyframelessKit

class InstalledTemplateVersions: ObservableObject {
	static let shared = InstalledTemplateVersions()

	@Published private var versions: [String: Int]
	private let filename = "installed_template_versions.json"

	private init() {
		versions = KKStore.load([String: Int].self, from: filename) ?? [:]
	}

	func version(for templateID: String) -> Int {
		versions[templateID] ?? 0
	}

	func setVersion(_ version: Int, for templateID: String) {
		versions[templateID] = version
		KKStore.save(versions, to: filename)
	}
}
