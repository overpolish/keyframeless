/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct PillToggle<Value: Hashable>: View {
	@Binding var selection: Value
	let options: [(label: String, value: Value, icon: String?, color: Color?)]

	init(
		selection: Binding<Value>,
		options: [(label: String, value: Value, icon: String?, color: Color?)]
	) {
		_selection = selection
		self.options = options
	}

	init(
		selection: Binding<Value>,
		options: [(label: String, value: Value)]
	) {
		_selection = selection
		self.options = options.map { ($0.label, $0.value, nil, nil) }
	}

	var body: some View {
		HStack(spacing: 2) {
			ForEach(options.indices, id: \.self) { i in
				let option = options[i]
				let isSelected = selection == option.value
				let activeColor = option.color ?? Color.kkAccent
				Button {
					selection = option.value
				} label: {
					HStack(spacing: 3) {
						if let icon = option.icon {
							Image(systemName: icon)
								.font(.system(size: 8, weight: .medium))
						}
						Text(option.label)
							.font(.system(size: 10, weight: .medium))
					}
					.padding(.horizontal, 8)
					.padding(.vertical, 3)
					.background {
						if isSelected {
							Capsule().fill(activeColor.opacity(0.15))
						}
					}
					.foregroundStyle(isSelected ? activeColor : .secondary)
					.contentShape(Capsule())
				}
				.buttonStyle(.plain)
			}
		}
		.padding(3)
		.background(Capsule().fill(Color.white.opacity(0.08)))
	}
}
