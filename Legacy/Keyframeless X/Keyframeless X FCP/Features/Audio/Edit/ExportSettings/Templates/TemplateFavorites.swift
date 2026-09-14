/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine

class TemplateFavorites: ObservableObject {
	static let shared = TemplateFavorites()
	@Published private(set) var ids: Set<String> = []

	private init() {
		ids = Set(KKStore.load([String].self, from: "template_favorites.json") ?? [])
	}

	func contains(_ id: String) -> Bool { ids.contains(id) }

	func toggle(_ id: String) {
		if ids.contains(id) {
			ids.remove(id)
		} else {
			ids.insert(id)
		}
		KKStore.save(Array(ids), to: "template_favorites.json")
	}
}
