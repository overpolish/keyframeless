/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

/// Flex-wrap container, equivalent to CSS `display: flex; flex-wrap: wrap;
/// align-items: center; justify-content: center`. Subviews are laid
/// left-to-right at their ideal size and wrap to a new line when the next one
/// would overflow the available width. Because each subview is given its ideal
/// width, its content (e.g. a pill label) never wraps or truncates: the pills
/// wrap as whole units, the text inside them does not. Each line is centred
/// horizontally; subviews are centred vertically within their line.
struct FlowLayout: Layout {
	var spacing: CGFloat = KKSpacingMD
	var lineSpacing: CGFloat = KKSpacingSM

	func sizeThatFits(
		proposal: ProposedViewSize, subviews: Subviews,
		cache: inout Void
	) -> CGSize {
		let maxWidth = proposal.width ?? .infinity
		let lines = computeLines(maxWidth: maxWidth, subviews: subviews)
		let width = lines.map(\.width).max() ?? 0
		let height =
			lines.reduce(0) { $0 + $1.height }
			+ lineSpacing * CGFloat(max(0, lines.count - 1))
		return CGSize(width: min(width, maxWidth), height: height)
	}

	func placeSubviews(
		in bounds: CGRect, proposal: ProposedViewSize,
		subviews: Subviews, cache: inout Void
	) {
		let lines = computeLines(maxWidth: bounds.width, subviews: subviews)
		var y = bounds.minY
		for line in lines {
			var x = bounds.minX + max(0, (bounds.width - line.width) / 2)
			for item in line.items {
				subviews[item.index].place(
					at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
					proposal: ProposedViewSize(item.size))
				x += item.size.width + spacing
			}
			y += line.height + lineSpacing
		}
	}

	private struct Line {
		var items: [(index: Int, size: CGSize)] = []
		var width: CGFloat = 0
		var height: CGFloat = 0
	}

	private func computeLines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
		var lines: [Line] = []
		var current = Line()
		for index in subviews.indices {
			let size = subviews[index].sizeThatFits(.unspecified)
			let projected =
				current.items.isEmpty ? size.width : current.width + spacing + size.width
			if !current.items.isEmpty && projected > maxWidth {
				lines.append(current)
				current = Line()
			}
			let x = current.items.isEmpty ? 0 : current.width + spacing
			current.items.append((index, size))
			current.width = x + size.width
			current.height = max(current.height, size.height)
		}
		if !current.items.isEmpty { lines.append(current) }
		return lines
	}
}
