/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct ClipSelectionToolbar: View {
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>
	var allowedIndices: Set<Int>?
	var showOverlapsLegend: Bool = false

	var body: some View {
		let allowed = allowedIndices ?? Set(clips.indices)
		let hasMain = allowed.contains { !clips[$0].isCompound }
		let hasCompound = allowed.contains { clips[$0].isCompound }

		HStack(spacing: KKSpacingLG) {
			if showOverlapsLegend {
				OverlapsLegend()
			}
			ToolbarGroup {
				if hasMain {
					ClipTypeFilterButton(label: String(localized: "Main"), color: Color.kkAccent) {
						selectedClips = allowed.filter { !clips[$0].isCompound }
					}
					ToolbarDivider()
				}
				if hasCompound {
					ClipTypeFilterButton(
						label: String(localized: "Compound"), color: Color.kkCompoundAccent
					) {
						selectedClips = allowed.filter { clips[$0].isCompound }
					}
					ToolbarDivider()
				}
				ClipActionButton(
					label: String(localized: "Select All"),
					systemImage: "checkmark.rectangle.stack.fill"
				) {
					selectedClips = allowed
				}
				ToolbarDivider()
				ClipActionButton(
					label: String(localized: "Deselect All"), systemImage: "rectangle.stack"
				) {
					selectedClips = []
				}
			}
			.disabled(clips.isEmpty)
		}
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

private struct OverlapsLegend: View {
	var body: some View {
		HStack(spacing: KKSpacingMD) {
			DiagonalStripesSwatch()
				.frame(width: 14, height: 10)
			Text("Overlaps")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
	}
}

private struct DiagonalStripesSwatch: View {
	var body: some View {
		Canvas { ctx, size in
			let stripeWidth: CGFloat = 2
			let stripeSpacing: CGFloat = 1.5
			let stride = stripeWidth + stripeSpacing
			let diagonal = size.width + size.height
			let color = Color(nsColor: NSColor.error().withAlphaComponent(0.55))
			var offset: CGFloat = -size.height
			while offset < diagonal {
				var path = Path()
				path.move(to: CGPoint(x: offset, y: size.height))
				path.addLine(to: CGPoint(x: offset + stripeWidth, y: size.height))
				path.addLine(to: CGPoint(x: offset + size.height + stripeWidth, y: 0))
				path.addLine(to: CGPoint(x: offset + size.height, y: 0))
				path.closeSubpath()
				ctx.fill(path, with: .color(color))
				offset += stride
			}
		}
		.clipShape(RoundedRectangle(cornerRadius: 2))
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
