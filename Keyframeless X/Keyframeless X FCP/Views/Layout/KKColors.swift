/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

extension Color {
	static var kkAccent: Color { .accentColor }
	static var kkCompoundAccent: Color { Color(nsColor: NSColor(name: nil) { _ in NSColor.controlAccentColor.compound() }) }
	static let kkWarning = Color(nsColor: .warning())
	static let kkError = Color(nsColor: .error())

	static func kkClipColor(isCompound: Bool) -> Color {
		isCompound ? .kkCompoundAccent : .kkAccent
	}
}
