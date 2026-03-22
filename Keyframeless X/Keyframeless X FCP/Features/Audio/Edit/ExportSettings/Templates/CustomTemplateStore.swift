/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

class CustomTemplateStore {
	static let shared = CustomTemplateStore()
	private(set) var templates: [CaptionTemplate] = []

	private init() {
		templates = KKStore.load([CaptionTemplate].self, from: "custom_templates.json") ?? []
	}

	func add(_ template: CaptionTemplate) {
		guard !templates.contains(where: { $0.id == template.id }) else { return }
		templates.append(template)
		KKStore.save(templates, to: "custom_templates.json")
	}

	func remove(_ template: CaptionTemplate) {
		templates.removeAll { $0.id == template.id }
		KKStore.save(templates, to: "custom_templates.json")
	}
}
