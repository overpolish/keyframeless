/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

enum CaptionLineCount: String, Codable {
	case one, two
}

struct CaptionStyleSettings: Codable, Equatable {
	var maxWordsPerLine: Double = 5
	var captionLines: CaptionLineCount = .two
	var allCaps: Bool = false
	var censorProfanity: Bool = true
	var stripPunctuation: Bool = true
	var keepQuestionMarks: Bool = true
}

class CaptionStyleDefaults {
	static let shared = CaptionStyleDefaults()
	private(set) var settings = CaptionStyleSettings()

	private init() {
		settings =
			KKStore.load(CaptionStyleSettings.self, from: "caption_style_defaults.json")
			?? CaptionStyleSettings()
	}

	func save(_ settings: CaptionStyleSettings) {
		self.settings = settings
		KKStore.save(settings, to: "caption_style_defaults.json")
	}
}

struct TextStyleSettings: Codable, Equatable {
	var textWidthPercent: Double = 80
	var textSize: Double = 100
	var textYPosition: Double = 20
	var textFont: String = "HelveticaNeue"
}

class TextStyleDefaults {
	static let shared = TextStyleDefaults()
	private(set) var settings = TextStyleSettings()

	private init() {
		settings =
			KKStore.load(TextStyleSettings.self, from: "text_style_defaults.json")
			?? TextStyleSettings()
	}

	func save(_ settings: TextStyleSettings) {
		self.settings = settings
		KKStore.save(settings, to: "text_style_defaults.json")
	}
}
