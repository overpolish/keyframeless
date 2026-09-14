/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct PlayButton: View {
	let isPlaying: Bool
	var size: CGFloat = 16
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			ZStack {
				Circle()
					.fill(.white.opacity(0.35))
					.shadow(color: .black.opacity(0.5), radius: 4)
				Image(systemName: isPlaying ? "pause.fill" : "play.fill")
					.font(.system(size: size * 0.45, weight: .regular))
					.foregroundStyle(.white.opacity(0.9))
					.offset(x: isPlaying ? -0.5 : size * 0.04 - 0.5)
			}
			.frame(width: size, height: size)
			.contentShape(Circle())
		}
		.buttonStyle(.plain)
	}
}
