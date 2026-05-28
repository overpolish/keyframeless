/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessAI
import KeyframelessKit
import SwiftUI

struct AITransformPreviewModal: View {
	@ObservedObject var batch: AITransformBatch
	let onApply: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		ModalContainer(width: 620, onDismiss: onDismiss) {
			VStack(alignment: .leading, spacing: KKSpacingMD) {
				header

				if batch.items.isEmpty {
					Text("No transcribed clips in selection.")
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
						.padding(.vertical, KKPaddingLG)
				} else {
					ScrollView {
						VStack(alignment: .leading, spacing: KKSpacingLG) {
							ForEach(clipGroups, id: \.clipIndex) { group in
								clipGroupView(group)
							}
						}
					}
					.frame(maxHeight: 420)
				}

				footer
			}
		}
	}

	private struct ClipGroup {
		let clipIndex: Int
		let clipName: String
		let itemIndices: [Int]
	}

	private var clipGroups: [ClipGroup] {
		var order: [Int] = []
		var byClip: [Int: ClipGroup] = [:]
		for (i, item) in batch.items.enumerated() {
			if byClip[item.clipIndex] == nil {
				byClip[item.clipIndex] = ClipGroup(
					clipIndex: item.clipIndex, clipName: item.clipName, itemIndices: [i])
				order.append(item.clipIndex)
			} else {
				let existing = byClip[item.clipIndex]!
				byClip[item.clipIndex] = ClipGroup(
					clipIndex: existing.clipIndex, clipName: existing.clipName,
					itemIndices: existing.itemIndices + [i])
			}
		}
		return order.compactMap { byClip[$0] }
	}

	@ViewBuilder
	private func clipGroupView(_ group: ClipGroup) -> some View {
		let applicable = group.itemIndices.filter { batch.items[$0].alignedWords != nil }
		let includedHere = applicable.filter { batch.items[$0].include }.count
		let allOn = !applicable.isEmpty && includedHere == applicable.count
		let mixed = includedHere > 0 && !allOn

		VStack(alignment: .leading, spacing: KKSpacingSM) {
			HStack(spacing: KKSpacingSM) {
				Toggle(
					isOn: Binding(
						get: { allOn },
						set: { newValue in
							for i in applicable { batch.items[i].include = newValue }
						}
					)
				) { EmptyView() }
					.toggleStyle(.checkbox)
					.disabled(applicable.isEmpty)
					.opacity(mixed ? 0.5 : 1)
				Text(group.clipName)
					.font(.system(size: 12, weight: .semibold))
					.lineLimit(1)
				Text("\(group.itemIndices.count)")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(.secondary)
					.padding(.horizontal, 6)
					.padding(.vertical, 1)
					.background(Capsule().fill(Color.white.opacity(0.08)))
				Spacer()
			}

			VStack(alignment: .leading, spacing: KKSpacingSM) {
				ForEach(group.itemIndices, id: \.self) { idx in
					AITransformPreviewRow(
						item: $batch.items[idx],
						isRunning: batch.isRunning
					)
				}
			}
			.padding(.leading, 22)
		}
	}

	private var header: some View {
		HStack(spacing: KKSpacingMD) {
			Text("AI Transform Preview")
				.font(.title3)
			Text("\u{2022}")
				.foregroundStyle(.tertiary)
			Text("\u{201C}\(batch.instruction)\u{201D}")
				.font(.system(size: 12))
				.foregroundStyle(.secondary)
				.italic()
			Spacer()
			if batch.isRunning {
				ProgressView().controlSize(.small)
			}
		}
	}

	private var footer: some View {
		HStack {
			let includedCount = batch.items.filter { $0.include && $0.alignedWords != nil }.count
			let failedCount = batch.items.filter {
				if case .failed = $0.status { return true } else { return false }
			}.count
			Text(
				"\(includedCount) of \(batch.items.count) will be applied"
					+ (failedCount > 0 ? "  \u{2022}  \(failedCount) failed" : "")
			)
			.font(.caption)
			.foregroundStyle(.secondary)
			Spacer()
			Button("Cancel", action: onDismiss)
				.keyboardShortcut(.cancelAction)
			Button("Apply", action: onApply)
				.keyboardShortcut(.defaultAction)
				.disabled(batch.isRunning || includedCount == 0)
		}
	}
}

private struct AITransformPreviewRow: View {
	@Binding var item: AITransformBatch.Item
	let isRunning: Bool

	var body: some View {
		HStack(alignment: .top, spacing: KKSpacingSM) {
			Toggle(isOn: $item.include) { EmptyView() }
				.toggleStyle(.checkbox)
				.disabled(item.alignedWords == nil)
				.padding(.top, 2)
			VStack(alignment: .leading, spacing: 2) {
				Text(item.originalText)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
				if let result = item.resultText {
					Text(result)
						.font(.system(size: 11))
						.foregroundStyle(.primary)
						.textSelection(.enabled)
				} else if case .failed(let msg) = item.status {
					Text(msg)
						.font(.system(size: 11))
						.foregroundStyle(.red)
				} else if isRunning {
					Text("Working\u{2026}")
						.font(.system(size: 11))
						.foregroundStyle(.tertiary)
				}
			}
			Spacer(minLength: 6)
			status
		}
		.padding(.horizontal, KKPaddingMD)
		.padding(.vertical, KKPaddingSM)
		.background(
			RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
		)
	}

	@ViewBuilder
	private var status: some View {
		switch item.status {
		case .pending:
			ProgressView().controlSize(.small)
		case .ready:
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 11))
				.foregroundStyle(.green)
		case .failed:
			Image(systemName: "xmark.circle.fill")
				.font(.system(size: 11))
				.foregroundStyle(.red)
		}
	}
}
