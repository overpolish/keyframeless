/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct UntranscribedClipRow: View {
	let clipName: String
	let clipIndex: Int
	let isCompound: Bool
	let isHighlighted: Bool
	@Binding var hoveredClipIndex: Int?
	var onTranscribe: () -> Void

	private var clipColor: Color { .kkClipColor(isCompound: isCompound) }

	var body: some View {
		HStack(spacing: KKSpacingLG) {
			Circle()
				.fill(clipColor.opacity(0.5))
				.frame(width: 6, height: 6)
			Text(clipName)
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(.tertiary)
			Spacer()
			Button {
				onTranscribe()
			} label: {
				Text("Transcribe")
					.font(.system(size: 11))
			}
			.buttonStyle(.plain)
			.foregroundStyle(clipColor)
		}
		.padding(.vertical, KKPaddingSM)
		.padding(.horizontal, KKPaddingSM)
		.background(
			RoundedRectangle(cornerRadius: CGFloat(KKRadiusMD))
				.fill(clipColor.opacity(isHighlighted ? 0.12 : 0))
		)
		.contentShape(RoundedRectangle(cornerRadius: CGFloat(KKRadiusSM)))
		.onHover { hovering in
			hoveredClipIndex = hovering ? clipIndex : nil
		}
	}
}
