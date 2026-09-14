/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

struct HelperText: View {
	let text: String
	var systemImage: String? = nil
	var warning: Bool = false

	init(_ text: String, systemImage: String? = nil, warning: Bool = false) {
		self.text = text
		self.systemImage = systemImage
		self.warning = warning
	}

	var body: some View {
		let content = HStack(spacing: 4) {
			if let systemImage {
				Image(systemName: systemImage)
			}
			Text(text)
		}
		.font(.system(size: 10, weight: .light))

		if warning {
			content.foregroundStyle(Color.kkWarning)
		} else {
			content.foregroundStyle(.tertiary)
		}
	}
}
