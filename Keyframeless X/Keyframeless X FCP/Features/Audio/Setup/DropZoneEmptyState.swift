/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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
		case .denied: return Color(nsColor: .error())
		case .dropped: return Color(nsColor: .warning())
		}
	}

	private var label: String {
		switch dropState {
		case .idle: return "Drop FCP clips here"
		case .denied: return "Cannot drop library or event"
		case .dropped: return "No dialogue found"
		}
	}
}
