/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

struct AIActionTab: View {
	let selectedCount: Int
	let productContext: String
	let examples: [AIPromptExample]
	let placeholder: String
	let isPluginMode: Bool
	let onRun: (String) -> Void

	@StateObject private var draft = AIDraftState.shared
	@StateObject private var recents = AIRecentPrompts.shared
	@StateObject private var keyState = AIKeyState.shared
	@FocusState private var promptFocused: Bool

	private var canRun: Bool {
		!draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let answer = draft.pendingAnswer {
				answerCard(answer)
			}
			if !isPluginMode { selectionLine }
			promptEditor
			if let err = draft.routingError {
				Text(err)
					.font(.system(size: 10))
					.foregroundStyle(.red)
			}
			if !examples.isEmpty { examplesRow }
			if !recents.prompts.isEmpty {
				recentsRow
			}
			footer
		}
		.animation(.easeInOut(duration: 0.18), value: draft.pendingAnswer != nil)
		// While a LOCAL request is in flight, poll the shared helper for how many
		// generations it's running, so the footer can show the count + a Stop
		// button. Restarts whenever isRouting flips; resets to 0 when idle.
		.task(id: draft.isRouting) {
			guard draft.isRouting, keyState.activeProvider == .local else {
				draft.localJobCount = 0
				return
			}
			while !Task.isCancelled && draft.isRouting {
				LocalLLM.activeJobCount { draft.localJobCount = $0 }
				try? await Task.sleep(nanoseconds: 1_500_000_000)
			}
			draft.localJobCount = 0
		}
		.onChange(of: draft.prompt) { _, newValue in
			// Only a real edit (typing) clears the done state - not the
			// programmatic clearPrompt() that fires when a mutation completes,
			// which would otherwise wipe the green sparkle the instant it lit.
			if !newValue.isEmpty && draft.didCompleteMutation {
				draft.didCompleteMutation = false
			}
			if !newValue.isEmpty && draft.didAnswerQuestion {
				draft.didAnswerQuestion = false
			}
		}
	}

	@ViewBuilder
	private func answerCard(_ answer: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "sparkles")
					.font(.system(size: 10))
					.foregroundStyle(Color.accentColor)
				Text(AILoc("Last answer"))
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(Color.aiSecondaryText)
					.textCase(.uppercase)
				Spacer()
				Button {
					draft.pendingAnswer = nil
				} label: {
					Image(systemName: "xmark")
						.font(.system(size: 9, weight: .medium))
						.foregroundStyle(Color.aiSecondaryText)
				}
				.buttonStyle(.plain)
				.help(AILoc("Dismiss answer"))
			}
			ScrollView {
				Text(answer)
					.font(.system(size: 12))
					.foregroundStyle(.primary)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(8)
			}
			.frame(maxHeight: 160)
			.background(
				RoundedRectangle(cornerRadius: 5)
					.fill(Color(nsColor: .textBackgroundColor))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 5)
					.stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
			)
		}
	}

	private var selectionLine: some View {
		HStack(spacing: 4) {
			Image(systemName: selectedCount > 0 ? "checkmark.circle.fill" : "questionmark.circle")
				.font(.system(size: 10))
				.foregroundStyle(selectedCount > 0 ? Color.accentColor : .secondary)
			Text(
				selectedCount > 0
					? AILoc("\(selectedCount) selected · transforms apply here")
					: AILoc("No selection · transforms unavailable, questions still work")
			)
			.font(.system(size: 11))
			.foregroundStyle(Color.aiSecondaryText)
		}
	}

	private var promptEditor: some View {
		TextField(
			placeholder,
			text: $draft.prompt,
			axis: .vertical
		)
		.textFieldStyle(.roundedBorder)
		.font(.system(size: 12))
		.focused($promptFocused)
		.lineLimit(3...5)
		.onSubmit { runIfPossible() }
	}

	private var examplesRow: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(AILoc("Examples"))
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(Color.aiTertiaryText)
				.textCase(.uppercase)
			FlowLayout(spacing: 4) {
				ForEach(examples, id: \.label) { ex in
					Button {
						draft.prompt = ex.value
						promptFocused = true
					} label: {
						Text(ex.label)
							.font(.system(size: 11))
							.padding(.horizontal, 8)
							.padding(.vertical, 3)
							.background(
								Capsule().fill(Color.white.opacity(0.08))
							)
							.foregroundStyle(.primary)
					}
					.buttonStyle(.plain)
				}
			}
		}
	}

	private var recentsRow: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(AILoc("Recent"))
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(Color.aiTertiaryText)
				.textCase(.uppercase)
			FlowLayout(spacing: 4) {
				ForEach(recents.prompts, id: \.self) { p in
					Button {
						draft.prompt = p
						promptFocused = true
					} label: {
						Text(p)
							.font(.system(size: 11))
							.lineLimit(1)
							.truncationMode(.tail)
							.frame(maxWidth: 200)
							.padding(.horizontal, 8)
							.padding(.vertical, 3)
							.background(
								Capsule().strokeBorder(Color.white.opacity(0.12))
							)
							.foregroundStyle(Color.aiSecondaryText)
					}
					.buttonStyle(.plain)
				}
			}
		}
	}

	private var footer: some View {
		// Done = a mutation landed and the user hasn't started a new prompt.
		// In that state the button turns solid green (not the disabled-grey
		// accent button with green text, which read as broken).
		let isDone = draft.didCompleteMutation && !canRun && !draft.isRouting
		return HStack(spacing: 8) {
			if !keyState.activeIsConfigured {
				Label(
					keyState.activeProvider.requiresAPIKey
						? AILoc("No key for \(keyState.activeProvider.displayName)")
						: AILoc("No model selected"),
					systemImage: "exclamationmark.triangle.fill"
				)
				.font(.system(size: 10))
				.foregroundStyle(.orange)
			}
			Spacer()
			// Local request in flight: show how many jobs the helper is running and
			// a Stop button to cancel them (recovers a stuck/slow local session
			// without waiting out the timeout). Cloud has no helper queue.
			if draft.isRouting && keyState.activeProvider == .local {
				if draft.localJobCount > 0 {
					Text(AILoc("\(draft.localJobCount) running"))
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
						.monospacedDigit()
				}
				Button(role: .destructive) {
					// Mark as a deliberate cancel so the resulting error is swallowed,
					// stop the spinner immediately, and cancel the helper's job (which
					// also reclaims its GPU memory once it drains).
					draft.cancelRequested = true
					draft.isRouting = false
					draft.routingStatus = nil
					LocalLLM.cancelActiveJobs()
				} label: {
					Label(AILoc("Stop"), systemImage: "stop.fill")
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
			Button {
				runIfPossible()
			} label: {
				if draft.isRouting {
					HStack(spacing: 4) {
						ProgressView().controlSize(.small)
						Text(draft.routingStatus ?? AILoc("Thinking"))
					}
				} else if isDone {
					Label(AILoc("Done"), systemImage: "checkmark")
				} else {
					Text(AILoc("Run"))
				}
			}
			.buttonStyle(.borderedProminent)
			.tint(isDone ? Color(red: 0.30, green: 0.85, blue: 0.45) : .accentColor)
			.keyboardShortcut(.defaultAction)
			.disabled(draft.isRouting || (!isDone && (!canRun || !keyState.activeIsConfigured)))
		}
	}

	private func runIfPossible() {
		let trimmed = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard canRun, keyState.activeIsConfigured else { return }
		draft.routingError = nil
		draft.didCompleteMutation = false
		draft.didAnswerQuestion = false
		draft.cancelRequested = false  // new run: don't swallow its errors

		if isPluginMode {
			// Plugin host owns routing: it has live timeline state and a custom
			// agent. Just hand the prompt over and let it drive draft state.
			recents.record(trimmed)
			onRun(trimmed)
			return
		}

		draft.isRouting = true
		draft.pendingAnswer = nil
		let captured = (selectedCount, productContext, trimmed)
		Task { @MainActor in
			do {
				let intent = try await AIRouter.routeStreaming(
					captured.2,
					selectedCount: captured.0,
					productContext: captured.1
				) { partial in
					// First answer token arrived: drop the spinner, reveal the answer
					// card, and keep filling it as tokens stream in. (A transform never
					// calls this - it stays a spinner until its preview popover opens.)
					draft.isRouting = false
					draft.didAnswerQuestion = true
					draft.pendingAnswer = partial
				}
				// Record both questions and transforms in recents (the plugin branch
				// above records unconditionally too); only a thrown route skips it.
				recents.record(captured.2)
				switch intent {
				case .transform(let cleanInstruction):
					draft.prompt = ""
					// Keep the icon animating right up until the host puts its
					// transform preview popover on screen - onRun opens it, so
					// only stop the spinner once it returns.
					onRun(cleanInstruction)
					draft.isRouting = false
				case .answer(let reply):
					draft.isRouting = false
					draft.pendingAnswer = reply
					draft.didAnswerQuestion = true
				}
			} catch {
				draft.isRouting = false
				// A deliberate Stop reports back as an error; don't show it as one.
				if draft.cancelRequested {
					draft.cancelRequested = false
				} else {
					draft.routingError = error.localizedDescription
				}
			}
		}
	}
}

// Tiny flow layout for chip wrapping. SwiftUI's built-in doesn't ship
// on macOS 14, so a 30-line implementation gets the job done.
struct FlowLayout: Layout {
	var spacing: CGFloat = 4

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? .infinity
		var x: CGFloat = 0
		var y: CGFloat = 0
		var rowHeight: CGFloat = 0
		var totalWidth: CGFloat = 0
		for s in subviews {
			let size = s.sizeThatFits(.unspecified)
			if x + size.width > width, x > 0 {
				y += rowHeight + spacing
				x = 0
				rowHeight = 0
			}
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
			totalWidth = max(totalWidth, x)
		}
		return CGSize(width: totalWidth, height: y + rowHeight)
	}

	func placeSubviews(
		in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) {
		let width = bounds.width
		var x: CGFloat = bounds.minX
		var y: CGFloat = bounds.minY
		var rowHeight: CGFloat = 0
		for s in subviews {
			let size = s.sizeThatFits(.unspecified)
			if x - bounds.minX + size.width > width, x > bounds.minX {
				y += rowHeight + spacing
				x = bounds.minX
				rowHeight = 0
			}
			s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
	}
}
