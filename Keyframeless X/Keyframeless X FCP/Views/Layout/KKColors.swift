/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

extension Color {
	static let kkAccent = Color(nsColor: .accent() ?? .blue)
	static let kkWarning = Color(nsColor: .warning())
	static let kkError = Color(nsColor: .error())

	static func kkClipColor(isCompound: Bool) -> Color {
		isCompound ? .kkWarning : .kkAccent
	}
}
