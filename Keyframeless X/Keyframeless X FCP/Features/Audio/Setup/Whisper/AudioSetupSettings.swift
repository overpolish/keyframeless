/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

class AudioSetupSettings {

	static let shared = AudioSetupSettings()

	var selectedModel: String?
	var selectedLanguage: String?
	var translateToEnglish: Bool = false
	var hotWords: [String] = []

	private init() {
		if let state = KKStore.load(Persisted.self, from: "audio_setup_settings.json") {
			selectedModel = state.selectedModel
			selectedLanguage = state.selectedLanguage
			translateToEnglish = state.translateToEnglish ?? false
			hotWords = state.hotWords ?? []
		}
	}

	private struct Persisted: Codable {
		var selectedModel: String?
		var selectedLanguage: String?
		var translateToEnglish: Bool?
		var hotWords: [String]?
	}

	func save() {
		KKStore.save(
			Persisted(
				selectedModel: selectedModel, selectedLanguage: selectedLanguage,
				translateToEnglish: translateToEnglish, hotWords: hotWords
			),
			to: "audio_setup_settings.json")
	}

}
