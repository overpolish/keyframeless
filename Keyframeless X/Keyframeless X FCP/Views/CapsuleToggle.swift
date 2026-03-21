/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct CapsuleToggle: View {
	@Binding var isOn: Bool
	let label: String
	var systemImage: String? = nil
	var disabled: Bool = false

	var body: some View {
		Button {
			isOn.toggle()
		} label: {
			HStack(spacing: KKSpacingSM) {
				if let systemImage {
					Image(systemName: systemImage)
						.font(.system(size: 10))
				}
				Text(label)
					.font(.system(size: 10, weight: .medium))
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(
				Capsule().fill(
					isOn ? Color(nsColor: .accent()).opacity(0.2) : Color.white.opacity(0.08)
				)
			)
			.overlay(
				Capsule().strokeBorder(
					isOn ? Color(nsColor: .accent()).opacity(0.4) : Color.clear,
					lineWidth: KKBorderWidthXS
				)
			)
			.foregroundStyle(isOn ? .primary : .secondary)
		}
		.buttonStyle(.plain)
		.disabled(disabled)
		.opacity(disabled ? 0.4 : 1)
	}
}
