/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import SwiftUI

/// "Keyframeless AI vX available" banner shown at the top of the AI popover when
/// the installed helper is out of date. Ported from Steno's UpdateBanner, using
/// this package's own tokens (KeyframelessAI can't import KeyframelessKit).
struct AIUpdateBanner: View {
	let version: String
	let url: URL?
	let onDismiss: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "arrow.down.circle.fill")
				.font(.system(size: 12))
			Text(AILoc("Keyframeless AI \(version) available"))
				.font(.system(size: 11, weight: .medium))
			Spacer(minLength: 0)
			if let url {
				Button(AILoc("What's New")) { NSWorkspace.shared.open(url) }
					.buttonStyle(.borderless)
					.font(.system(size: 11, weight: .semibold))
			}
			Button(action: onDismiss) {
				Image(systemName: "xmark")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(Color.aiTertiaryText)
			}
			.buttonStyle(.borderless)
		}
		.foregroundStyle(Color.accentColor)
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(
			RoundedRectangle(cornerRadius: 8)
				.fill(Color.accentColor.opacity(0.1))
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
				)
		)
		.padding(.horizontal, 10)
		.padding(.top, 8)
	}
}
