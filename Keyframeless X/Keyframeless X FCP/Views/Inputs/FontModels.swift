/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine

enum FontCache {
	private static var cached: [FontFamily]?
	private static let queue = DispatchQueue(label: "font-cache", qos: .userInitiated)

	static func warmup() {
		queue.async {
			let families = FontFamily.all()
			DispatchQueue.main.async { cached = families }
		}
	}

	static var families: [FontFamily] {
		cached ?? FontFamily.all()
	}
}

class FontFavorites: ObservableObject {
	static let shared = FontFavorites()
	@Published private(set) var familyNames: Set<String> = []

	private init() {
		familyNames = KKStore.load(Set<String>.self, from: "font_favorites.json") ?? []
	}

	func contains(_ name: String) -> Bool { familyNames.contains(name) }

	func toggle(_ name: String) {
		if familyNames.contains(name) {
			familyNames.remove(name)
		} else {
			familyNames.insert(name)
		}
		KKStore.save(familyNames, to: "font_favorites.json")
	}
}

struct FontVariant: Identifiable {
	let postScriptName: String
	let styleName: String
	var id: String { postScriptName }
}

struct FontFamily: Identifiable {
	let name: String
	let variants: [FontVariant]
	var id: String { name }

	static func all() -> [FontFamily] {
		let manager = NSFontManager.shared
		return manager.availableFontFamilies.sorted().map { family in
			let members = manager.availableMembers(ofFontFamily: family) ?? []
			let variants = members.compactMap { member -> FontVariant? in
				guard let postScript = member[0] as? String,
					let style = member[1] as? String
				else { return nil }
				return FontVariant(postScriptName: postScript, styleName: style)
			}
			return FontFamily(name: family, variants: variants)
		}
	}
}
