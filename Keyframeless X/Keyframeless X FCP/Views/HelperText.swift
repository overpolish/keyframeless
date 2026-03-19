/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import SwiftUI

struct HelperText: View {
	let text: String
	var systemImage: String? = nil

	init(_ text: String, systemImage: String? = nil) {
		self.text = text
		self.systemImage = systemImage
	}

	var body: some View {
		HStack(spacing: 4) {
			if let systemImage {
				Image(systemName: systemImage)
			}
			Text(text)
		}
		.font(.system(size: 10, weight: .light))
		.foregroundStyle(.tertiary)
	}
}
