/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
	var onImportSRT: (() -> Void)? = nil

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
			if let onImportSRT {
				Button {
					onImportSRT()
				} label: {
					Text("Import SRT")
						.font(.system(size: 11))
				}
				.buttonStyle(.plain)
				.foregroundStyle(Color.kkWarning)
			}
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
