/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct UpdateBanner: View {
	let version: String
	let currentVersion: String
	let url: URL?
	let onDismiss: () -> Void

	var body: some View {
		HStack(spacing: KKSpacingLG) {
			Image(systemName: "arrow.down.circle.fill")
				.font(.system(size: 12))
			VStack(alignment: .leading, spacing: 1) {
				Text("Keyframeless X \(version) available")
					.font(.system(size: 11, weight: .medium))
				Text("You have \(currentVersion)")
					.font(.system(size: 9))
					.foregroundStyle(.secondary)
			}
			Spacer()
			if let url {
				Button("What's New") {
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

#if DEBUG
	#Preview {
		VStack(spacing: 12) {
			UpdateBanner(
				version: "2.2.0",
				currentVersion: "2.1.0",
				url: URL(string: "https://keyframeless.com/keyframelessx/"),
				onDismiss: {}
			)
			UpdateBanner(version: "3.0.0", currentVersion: "2.1.0", url: nil, onDismiss: {})
		}
		.padding()
		.frame(width: 440)
		.background(Color(nsColor: .windowBackground()))
	}
#endif
