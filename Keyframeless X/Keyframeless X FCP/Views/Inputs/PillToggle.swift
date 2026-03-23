/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct PillToggle<Value: Hashable>: View {
	@Binding var selection: Value
	let options: [(label: String, value: Value)]

	var body: some View {
		HStack(spacing: 2) {
			ForEach(options.indices, id: \.self) { i in
				let option = options[i]
				Button {
					selection = option.value
				} label: {
					Text(option.label)
						.font(.system(size: 10, weight: .medium))
						.padding(.horizontal, 8)
						.padding(.vertical, 3)
						.background {
							if selection == option.value {
								Capsule().fill(Color.kkAccent)
							}
						}
						.foregroundStyle(selection == option.value ? .white : .secondary)
						.contentShape(Capsule())
				}
				.buttonStyle(.plain)
			}
		}
		.padding(3)
		.background(Capsule().fill(Color.white.opacity(0.08)))
	}
}
