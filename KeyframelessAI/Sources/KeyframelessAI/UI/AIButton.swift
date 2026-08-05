/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

public struct AIButton: View {
	@State private var showPopover = false
	@StateObject private var keyState = AIKeyState.shared
	@StateObject private var draft = AIDraftState.shared

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
		placeholder: String? = nil,
		isPluginMode: Bool = false,
		onRun: @escaping (String) -> Void
	) {
		self.selectedCount = selectedCount
		self.productContext = productContext
		self.examples = examples
		self.placeholder =
			placeholder ?? AILoc("Describe what to do to the selected transcriptions…")
		self.isPluginMode = isPluginMode
		self.onRun = onRun
	}

	private var iconState: SparkleIcon.State {
		if !keyState.hasAnyKey { return .unconfigured }
		if draft.isRouting { return .running }
		if draft.didCompleteMutation || draft.didAnswerQuestion { return .done }
		return .idle
	}

	private var helpText: String {
		switch iconState {
		case .unconfigured: return AILoc("Configure Kai")
		case .running: return AILoc("Working")
		case .done: return AILoc("Done - click to review")
		case .idle: return AILoc("Ask Kai")
		}
	}

	public var body: some View {
		Button {
			// Opening (or otherwise tapping) the icon counts as the user
			// coming back to review, so clear the lingering "done" state.
			draft.didCompleteMutation = false
			draft.didAnswerQuestion = false
			showPopover.toggle()
		} label: {
			SparkleIcon(state: iconState)
				.frame(width: 18, height: 18)
				.contentShape(Rectangle())
		}
		.buttonStyle(.borderless)
		.help(helpText)
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

private struct SparkleIcon: View {
	enum State {
		/// No AI key - calm grey sparkle ("configure AI key").
		case unconfigured
		/// Key set, nothing happening - static colored sparkle (available).
		case idle
		/// A request is in flight - rotating gradient + shimmer.
		case running
		/// A transform was applied and not yet reviewed - green check sparkle.
		case done
	}

	let state: State

	private static let gradientColors = [
		Color(red: 1.00, green: 0.42, blue: 0.71),
		Color(red: 0.55, green: 0.36, blue: 1.00),
		Color(red: 0.20, green: 0.78, blue: 1.00),
		Color(red: 0.30, green: 1.00, blue: 0.78),
		Color(red: 1.00, green: 0.84, blue: 0.30),
		Color(red: 1.00, green: 0.42, blue: 0.71),
	]
	private static let doneColor = Color(red: 0.30, green: 0.85, blue: 0.45)
	/// Matches the sibling banner buttons ([NSColor inspectorLabel] = 179 grey)
	/// so the resting sparkle sits in the row without standing out.
	private static let restColor = Color(red: 0.702, green: 0.702, blue: 0.702)

	var body: some View {
		switch state {
		case .unconfigured, .idle:
			sparkle.foregroundStyle(SparkleIcon.restColor)
		case .running:
			TimelineView(.animation) { context in
				let t = context.date.timeIntervalSinceReferenceDate
				let angle = Angle.degrees((t * 60).truncatingRemainder(dividingBy: 360))
				let shimmer = 0.5 + 0.5 * sin(t * 2.2)
				gradientSparkle(angle: angle)
					.shadow(
						color: Color(red: 0.55, green: 0.36, blue: 1.00)
							.opacity(0.35 + 0.25 * shimmer),
						radius: 3 + 2 * shimmer
					)
			}
		case .done:
			sparkle
				.foregroundStyle(SparkleIcon.restColor)
				.overlay(alignment: .bottomTrailing) {
					Image(systemName: "checkmark.circle.fill")
						.font(.system(size: 8, weight: .bold))
						.foregroundStyle(.white, SparkleIcon.doneColor)
						.offset(x: 2, y: 2)
				}
		}
	}

	private var sparkle: some View {
		Image(systemName: "sparkles")
			.font(.system(size: 13, weight: .semibold))
	}

	private func gradientSparkle(angle: Angle) -> some View {
		sparkle
			.foregroundStyle(.white)
			.overlay {
				AngularGradient(
					colors: SparkleIcon.gradientColors,
					center: .center,
					angle: angle
				)
				.mask(sparkle)
			}
	}
}
