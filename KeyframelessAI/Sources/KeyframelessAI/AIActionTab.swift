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
			selectionLine
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
	}

	@ViewBuilder
	private func answerCard(_ answer: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "sparkles")
					.font(.system(size: 10))
					.foregroundStyle(Color.accentColor)
				Text("Last answer")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.secondary)
					.textCase(.uppercase)
				Spacer()
				Button {
					draft.pendingAnswer = nil
				} label: {
					Image(systemName: "xmark")
						.font(.system(size: 9, weight: .medium))
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.help("Dismiss answer")
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
					? "\(selectedCount) transcription\(selectedCount == 1 ? "" : "s") selected · transforms apply here"
					: "No selection · transforms unavailable, questions still work"
			)
			.font(.system(size: 11))
			.foregroundStyle(.secondary)
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
			Text("Examples")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.tertiary)
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
			Text("Recent")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.tertiary)
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
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
				}
			}
		}
	}

	private var footer: some View {
		HStack(spacing: 8) {
			if !keyState.activeIsConfigured {
				Label(
					"No key for \(keyState.activeProvider.displayName)",
					systemImage: "exclamationmark.triangle.fill"
				)
				.font(.system(size: 10))
				.foregroundStyle(.orange)
			}
			Spacer()
			Button {
				runIfPossible()
			} label: {
				if draft.isRouting {
					HStack(spacing: 4) {
						ProgressView().controlSize(.small)
						Text("Thinking…")
					}
				} else {
					Text("Run")
				}
			}
			.keyboardShortcut(.defaultAction)
			.disabled(!canRun || !keyState.activeIsConfigured || draft.isRouting)
		}
	}

	private func runIfPossible() {
		let trimmed = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard canRun, keyState.activeIsConfigured else { return }
		draft.routingError = nil
		draft.isRouting = true
		let captured = (selectedCount, productContext, trimmed)
		Task { @MainActor in
			do {
				let intent = try await AIRouter.route(
					captured.2,
					selectedCount: captured.0,
					productContext: captured.1
				)
				draft.isRouting = false
				switch intent {
				case .transform(let cleanInstruction):
					recents.record(captured.2)
					draft.prompt = ""
					onRun(cleanInstruction)
				case .answer(let reply):
					draft.pendingAnswer = reply
				}
			} catch {
				draft.isRouting = false
				draft.routingError = error.localizedDescription
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
