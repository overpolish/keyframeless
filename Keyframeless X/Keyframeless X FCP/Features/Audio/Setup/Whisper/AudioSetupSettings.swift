/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

class AudioSetupSettings {

	static let shared = AudioSetupSettings()

	var selectedModel: String?
	var selectedLanguage: String?
	var translateToEnglish: Bool = false
	var terms: [String] = []

	private init() {
		if let state = KKStore.load(Persisted.self, from: "audio_setup_settings.json") {
			selectedModel = state.selectedModel
			selectedLanguage = state.selectedLanguage
			translateToEnglish = state.translateToEnglish ?? false
			terms = state.terms ?? []
		}
	}

	private struct Persisted: Codable {
		var selectedModel: String?
		var selectedLanguage: String?
		var translateToEnglish: Bool?
		var terms: [String]?

		enum CodingKeys: String, CodingKey {
			case selectedModel, selectedLanguage, translateToEnglish
			case terms = "hotWords"
		}
	}

	func save() {
		KKStore.save(
			Persisted(
				selectedModel: selectedModel, selectedLanguage: selectedLanguage,
				translateToEnglish: translateToEnglish, terms: terms
			),
			to: "audio_setup_settings.json")
	}

}
