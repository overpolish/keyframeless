/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct ClipSelectionToolbar: View {
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>

	var body: some View {
		let hasMain = clips.contains { !$0.isCompound }
		let hasCompound = clips.contains { $0.isCompound }

		ToolbarGroup {
			if hasMain {
				ClipTypeFilterButton(label: "Main", color: Color(nsColor: .accent() ?? .blue)) {
					selectedClips = Set(clips.indices.filter { !clips[$0].isCompound })
				}
				ToolbarDivider()
			}
			if hasCompound {
				ClipTypeFilterButton(
					label: "Compound", color: Color(nsColor: .warning() ?? .yellow)
				) {
					selectedClips = Set(clips.indices.filter { clips[$0].isCompound })
				}
				ToolbarDivider()
			}
			ClipActionButton(label: "Select All", systemImage: "checkmark.rectangle.stack.fill") {
				selectedClips = Set(clips.indices)
			}
			ToolbarDivider()
			ClipActionButton(label: "Deselect All", systemImage: "rectangle.stack") {
				selectedClips = []
			}
		}
		.disabled(clips.isEmpty)
	}
}

private struct ClipTypeFilterButton: View {
	let label: String
	let color: Color
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			ToolbarCell {
				HStack(spacing: KKSpacingLG) {
					Circle()
						.fill(color)
						.frame(width: 6, height: 6)
					Text(label)
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			}
		}
		.buttonStyle(.plain)
	}
}

private struct ClipActionButton: View {
	let label: String
	let systemImage: String
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			ToolbarCell {
				HStack(spacing: KKSpacingLG) {
					Image(systemName: systemImage)
					Text(label)
				}
				.font(.caption2)
				.foregroundStyle(.secondary)
			}
		}
		.buttonStyle(.plain)
	}
}
