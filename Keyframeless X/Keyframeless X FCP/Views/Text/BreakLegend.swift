/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct BreakLegend: View {
	var body: some View {
		HStack(spacing: KKSpacingXL) {
			LegendItem(label: "Auto", color: Color(NSColor.warning()))
			LegendItem(label: "Manual", color: Color(.systemBlue))
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
