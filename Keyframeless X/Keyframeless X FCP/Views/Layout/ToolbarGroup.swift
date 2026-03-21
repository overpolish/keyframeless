/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import SwiftUI

struct ToolbarGroup<Content: View>: View {
	@ViewBuilder let content: () -> Content

	var body: some View {
		HStack(spacing: 0) {
			content()
		}
		.background(RoundedRectangle(cornerRadius: 999).fill(Color.white.opacity(0.06)))
		.overlay(
			RoundedRectangle(cornerRadius: 999).strokeBorder(
				Color.secondary.opacity(0.2), lineWidth: 1))
	}
}

struct ToolbarDivider: View {
	var body: some View {
		Rectangle()
			.fill(Color.secondary.opacity(0.2))
			.frame(width: 1, height: 14)
	}
}

struct ToolbarCell<Content: View>: View {
	@ViewBuilder let content: () -> Content

	var body: some View {
		content()
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.contentShape(Rectangle())
	}
}
