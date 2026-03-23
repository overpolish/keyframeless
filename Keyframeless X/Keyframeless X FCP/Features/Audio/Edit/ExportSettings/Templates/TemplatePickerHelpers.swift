/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

let cardAspect: CGFloat = 16.0 / 9.0
let cardMinWidth: CGFloat = 160
let cardSpacing = KKSpacingLG
let selectionInset: CGFloat = 3

enum KeyframelessItem: Identifiable {
	case installed(CaptionTemplate)
	case community(CommunityTemplate)

	var id: String {
		switch self {
		case .installed(let t): return t.id
		case .community(let t): return "community-\(t.id)"
		}
	}

	var name: String {
		switch self {
		case .installed(let t): return t.name
		case .community(let t): return t.name
		}
	}
}

struct TemplateSection<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingSM) {
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
			TemplateGrid { content }
		}
	}
}

struct TemplateGrid<Content: View>: View {
	@ViewBuilder let content: Content

	var body: some View {
		let gridColumns = [
			GridItem(.adaptive(minimum: cardMinWidth), spacing: cardSpacing)
		]

		LazyVGrid(columns: gridColumns, spacing: cardSpacing) {
			content
		}
	}
}

struct MotiDropTarget: View {
	var onPickFile: (() -> Void)?

	var body: some View {
		VStack(spacing: KKSpacingSM) {
			ZStack {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(style: StrokeStyle(lineWidth: KKBorderWidthXS, dash: [4, 3]))
					.foregroundStyle(.secondary.opacity(0.3))
				Image(systemName: "plus")
					.font(.system(size: 14))
					.foregroundStyle(.secondary.opacity(0.5))
			}
			.aspectRatio(cardAspect, contentMode: .fit)
			.padding(selectionInset)
			Text("Drop .moti")
				.font(.system(size: 9))
				.foregroundStyle(.secondary.opacity(0.5))
		}
		.contentShape(Rectangle())
		.onTapGesture { onPickFile?() }
	}
}
