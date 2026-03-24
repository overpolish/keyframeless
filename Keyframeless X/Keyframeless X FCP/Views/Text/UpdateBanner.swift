/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct UpdateBanner: View {
	let message: String
	let url: URL?
	let onDismiss: () -> Void

	var body: some View {
		HStack(spacing: KKSpacingLG) {
			Image(systemName: "arrow.down.circle.fill")
				.font(.system(size: 12))
			Text(message)
				.font(.system(size: 11, weight: .medium))
			Spacer()
			if let url {
				Button("Download") {
					NSWorkspace.shared.open(url)
				}
				.buttonStyle(.borderless)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(Color.kkAccent)
			}
			Button {
				onDismiss()
			} label: {
				Image(systemName: "xmark")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.borderless)
		}
		.foregroundStyle(Color.kkAccent)
		.padding(.horizontal, KKPaddingXL)
		.padding(.vertical, KKPaddingMD)
		.background(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(Color.kkAccent.opacity(0.1))
				.overlay(
					RoundedRectangle(cornerRadius: KKRadiusMD)
						.strokeBorder(Color.kkAccent.opacity(0.2), lineWidth: KKBorderWidthXS)
				)
		)
	}
}
