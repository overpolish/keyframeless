/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct PillIconToggle<Value: Hashable>: View {
	@Binding var selection: Value
	let options: [(label: String, systemImage: String, value: Value)]
	var disabledValues: Set<Value> = []

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			ForEach(options.indices, id: \.self) { i in
				let option = options[i]
				let isSelected = selection == option.value
				let isDisabled = disabledValues.contains(option.value)
				Button {
					selection = option.value
				} label: {
					Label(option.label, systemImage: option.systemImage)
						.font(.system(size: 12, weight: .medium))
						.padding(.horizontal, KKPaddingLG)
						.padding(.vertical, KKSpacingMD)
						.background {
							if isSelected {
								Capsule().fill(Color.white.opacity(0.15))
							}
						}
						.foregroundStyle(isSelected ? .primary : .secondary)
						.contentShape(Capsule())
						.opacity(isDisabled ? 0.35 : 1)
				}
				.buttonStyle(.plain)
				.disabled(isDisabled)
			}
		}
		.padding(KKPaddingSM)
		.background(Capsule().fill(Color.white.opacity(0.08)))
	}
}
