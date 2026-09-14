/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct DropZoneEmptyState: View {
	let dropState: AudioSetupView.DropState
	let isTargeted: Bool

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			Image(systemName: icon)
				.font(.title)
				.foregroundStyle(color)
			Text(label)
				.font(.title3)
				.foregroundStyle(color)
		}
		.blur(radius: isTargeted ? 3 : 0)
	}

	private var icon: String {
		switch dropState {
		case .idle: return "arrow.down.doc"
		case .denied: return "xmark.circle"
		case .dropped: return "exclamationmark.triangle"
		}
	}

	private var color: Color {
		switch dropState {
		case .idle: return Color(nsColor: .timelineLabel())
		case .denied: return Color.kkError
		case .dropped: return Color.kkWarning
		}
	}

	private var label: String {
		switch dropState {
		case .idle: return String(localized: "Drop FCP project (or clips) here")
		case .denied: return String(localized: "Cannot drop library or event")
		case .dropped: return String(localized: "No dialogue found")
		}
	}
}
