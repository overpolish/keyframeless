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
	/// Sonar: one filter button per audio role present, so users can analyze
	/// just the music, just the voice, etc. Off for Steno, where every clip is
	/// dialogue and a single "Dialogue" button would be noise.
	var showRoleFilters: Bool = false

	var body: some View {
		let allowed = allowedIndices ?? Set(clips.indices)
		let hasMain = allowed.contains { !clips[$0].isCompound }
		let hasCompound = allowed.contains { clips[$0].isCompound }
		let roles = showRoleFilters ? rolesPresent(in: allowed) : []

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
				ForEach(roles, id: \.self) { role in
					ClipTypeFilterButton(
						label: RoleColors.label(for: role) ?? role,
						color: Color(nsColor: RoleColors.color(for: role))
					) {
						selectedClips = allowed.filter { clips[$0].role == role }
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

	/// Distinct roles among the allowed clips, ordered by first appearance on
	/// the timeline so the buttons stay stable as the selection changes.
	private func rolesPresent(in allowed: Set<Int>) -> [String] {
		var seen: [String] = []
		for i in allowed.sorted() {
			guard let role = clips[i].role else { continue }
			if !seen.contains(role) { seen.append(role) }
		}
		return seen
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
