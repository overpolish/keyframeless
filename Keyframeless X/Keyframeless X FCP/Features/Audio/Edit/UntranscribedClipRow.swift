/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct UntranscribedClipRow: View {
	let clipName: String
	var onTranscribe: () -> Void

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Image(systemName: "waveform.badge.magnifyingglass")
				.font(.system(size: 11))
				.foregroundStyle(.tertiary)
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
			.foregroundStyle(Color(nsColor: .accent()))
		}
	}
}
