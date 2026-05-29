/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

extension Color {
	static var kkAccent: Color { .accentColor }
	static var kkCompoundAccent: Color {
		Color(nsColor: NSColor(name: nil) { _ in NSColor.controlAccentColor.compound() })
	}
	static let kkWarning = Color(nsColor: .warning())
	static let kkError = Color(nsColor: .error())
	static let kkSuccess = Color(nsColor: .success())

	static func kkClipColor(isCompound: Bool) -> Color {
		isCompound ? .kkCompoundAccent : .kkAccent
	}
}
