/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

extension Color {
	/// Legible stand-ins for `.secondary` / `.tertiary`, which wash out to near-
	/// invisible on the liquid-glass popover background. Opacity-on-primary keeps
	/// real contrast in both light and dark.
	static let aiSecondaryText = Color.primary.opacity(0.75)
	static let aiTertiaryText = Color.primary.opacity(0.55)
}
