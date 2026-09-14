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

	/// Opaque popover surface matching the kit's `inspectorBackground` (the dark
	/// fill used by every timeline / inspector popover in Final Cut). Keeps AI
	/// popover content legible instead of floating on see-through liquid glass.
	static let aiPopoverBackground = Color(
		red: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x16 / 255.0)
}
