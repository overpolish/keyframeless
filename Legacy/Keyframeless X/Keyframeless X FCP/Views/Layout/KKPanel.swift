/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct KKPanel: ViewModifier {
	var cornerRadius: CGFloat = KKRadiusMD + 4

	func body(content: Content) -> some View {
		content
			.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
			.background(
				RoundedRectangle(cornerRadius: cornerRadius)
					.fill(Color.white.opacity(0.04))
			)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(Color.secondary.opacity(0.15), lineWidth: KKBorderWidthXS)
			)
	}
}

extension View {
	func kkPanel(cornerRadius: CGFloat = KKRadiusMD + 4) -> some View {
		modifier(KKPanel(cornerRadius: cornerRadius))
	}

	func kkSelectableBackground(_ isSelected: Bool) -> some View {
		background(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(isSelected ? Color.kkAccent.opacity(0.12) : Color.clear)
		)
	}
}
