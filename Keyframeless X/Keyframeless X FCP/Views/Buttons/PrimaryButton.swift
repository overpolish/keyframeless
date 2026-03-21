/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct PrimaryButton: View {
	let label: String
	var systemImage: String? = nil
	let disabled: Bool
	var action: () -> Void = {}

	var body: some View {
		Button(action: action) {
			HStack(spacing: KKSpacingSM) {
				if let systemImage {
					Image(systemName: systemImage)
				}
				Text(label)
					.font(.system(size: 13, weight: .medium))
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, KKSpacingMD)
		}
		.buttonStyle(.borderedProminent)
		.tint(Color(nsColor: .accent() ?? .blue))
		.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
		.disabled(disabled)
	}
}
