/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct BreakLegend: View {
	var body: some View {
		HStack(spacing: KKSpacingXL) {
			LegendItem(label: "Auto", color: Color(NSColor.warning()))
			LegendItem(label: "Manual", color: Color.accentColor)
		}
	}
}

private struct LegendItem: View {
	let label: String
	let color: Color

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Text("|")
				.foregroundStyle(color)
			Text(label)
				.foregroundStyle(.tertiary)
		}
		.font(.system(size: 10, weight: .light))
	}
}
