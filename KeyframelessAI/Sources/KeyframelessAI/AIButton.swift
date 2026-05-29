/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

public struct AIButton: View {
	@State private var showPopover = false
	@StateObject private var keyState = AIKeyState.shared

	let selectedCount: Int
	let productContext: String
	let examples: [AIPromptExample]
	let placeholder: String
	let isPluginMode: Bool
	let onRun: (String) -> Void

	public init(
		selectedCount: Int,
		productContext: String,
		examples: [AIPromptExample] = AIPromptExample.stenoDefaults,
		placeholder: String = "Describe what to do to the selected transcriptions…",
		isPluginMode: Bool = false,
		onRun: @escaping (String) -> Void
	) {
		self.selectedCount = selectedCount
		self.productContext = productContext
		self.examples = examples
		self.placeholder = placeholder
		self.isPluginMode = isPluginMode
		self.onRun = onRun
	}

	public var body: some View {
		Button {
			showPopover.toggle()
		} label: {
			AnimatedSparkleIcon(animated: keyState.hasAnyKey)
				.frame(width: 18, height: 18)
				.contentShape(Rectangle())
		}
		.buttonStyle(.borderless)
		.help(keyState.hasAnyKey ? "AI" : "Configure AI key")
		.popover(isPresented: $showPopover, arrowEdge: .top) {
			AISettingsPopover(
				selectedCount: selectedCount,
				productContext: productContext,
				examples: examples,
				placeholder: placeholder,
				isPluginMode: isPluginMode,
				onRun: onRun,
				onDismiss: { showPopover = false }
			)
		}
	}
}

private struct AnimatedSparkleIcon: View {
	let animated: Bool

	var body: some View {
		if animated {
			TimelineView(.animation) { context in
				glyph(at: context.date.timeIntervalSinceReferenceDate)
			}
		} else {
			Image(systemName: "sparkles")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(.secondary)
		}
	}

	private func glyph(at t: TimeInterval) -> some View {
		let angle = Angle.degrees((t * 60).truncatingRemainder(dividingBy: 360))
		let shimmer = 0.5 + 0.5 * sin(t * 2.2)

		return Image(systemName: "sparkles")
			.font(.system(size: 13, weight: .semibold))
			.foregroundStyle(.white)
			.overlay {
				AngularGradient(
					colors: [
						Color(red: 1.00, green: 0.42, blue: 0.71),
						Color(red: 0.55, green: 0.36, blue: 1.00),
						Color(red: 0.20, green: 0.78, blue: 1.00),
						Color(red: 0.30, green: 1.00, blue: 0.78),
						Color(red: 1.00, green: 0.84, blue: 0.30),
						Color(red: 1.00, green: 0.42, blue: 0.71),
					],
					center: .center,
					angle: angle
				)
				.mask(
					Image(systemName: "sparkles")
						.font(.system(size: 13, weight: .semibold))
				)
			}
			.shadow(
				color: Color(red: 0.55, green: 0.36, blue: 1.00).opacity(0.35 + 0.25 * shimmer),
				radius: 3 + 2 * shimmer
			)
	}
}
