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
		ModalContainer(width: 640, onDismiss: onDismiss) {
			VStack(alignment: .leading, spacing: KKSpacingXL) {
				header

				if batch.items.isEmpty {
					Text("No transcribed clips in selection.")
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
						.padding(.vertical, KKPaddingLG)
				} else {
					ScrollShadowView {
						VStack(alignment: .leading, spacing: KKSpacingXL) {
							ForEach(clipGroups, id: \.clipIndex) { group in
								clipGroupView(group)
							}
						}
						.padding(KKPaddingXL)
					}
					.kkPanel()
					.frame(maxHeight: 460)
				}

				footer
			}
		}
	}

	private struct ClipGroup {
		let clipIndex: Int
		let clipName: String
		let isCompound: Bool
		let itemIndices: [Int]
	}

	private func groupCounts(_ group: ClipGroup) -> (added: Int, removed: Int) {
		var added = 0
		var removed = 0
		for idx in group.itemIndices {
			let item = batch.items[idx]
			guard let result = item.resultText else { continue }
			let c = AIWordDiff.counts(original: item.originalText, result: result)
			added += c.added
			removed += c.removed
		}
		return (added, removed)
	}

	private var clipGroups: [ClipGroup] {
		var order: [Int] = []
		var byClip: [Int: ClipGroup] = [:]
		for (i, item) in batch.items.enumerated() {
			if byClip[item.clipIndex] == nil {
				byClip[item.clipIndex] = ClipGroup(
					clipIndex: item.clipIndex, clipName: item.clipName,
					isCompound: item.isCompound, itemIndices: [i])
				order.append(item.clipIndex)
			} else {
				let existing = byClip[item.clipIndex]!
				byClip[item.clipIndex] = ClipGroup(
					clipIndex: existing.clipIndex, clipName: existing.clipName,
					isCompound: existing.isCompound,
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

		VStack(alignment: .leading, spacing: KKSpacingMD) {
			HStack(spacing: KKSpacingLG) {
				Toggle(
					isOn: Binding(
						get: { allOn },
						set: { newValue in
							for i in applicable { batch.items[i].include = newValue }
						}
					)
				) { EmptyView() }
				.toggleStyle(.checkbox)
				.tint(Color.kkClipColor(isCompound: group.isCompound))
				.disabled(applicable.isEmpty)
				.opacity(mixed ? 0.5 : 1)
				Text(group.clipName)
					.font(.system(size: 12, weight: .semibold))
					.lineLimit(1)
				Text("\(group.itemIndices.count)")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(.secondary)
					.padding(.horizontal, KKPaddingMD)
					.padding(.vertical, 1)
					.background(Capsule().fill(Color.secondary.opacity(0.15)))
				Spacer()
				let agg = groupCounts(group)
				if agg.added > 0 || agg.removed > 0 {
					DiffCountsBadge(counts: agg)
				}
			}

			VStack(alignment: .leading, spacing: KKSpacingSM) {
				ForEach(group.itemIndices, id: \.self) { idx in
					AITransformPreviewRow(
						item: $batch.items[idx],
						isRunning: batch.isRunning
					)
				}
			}
			.padding(.leading, KKPadding2XL + KKPaddingSM)
		}
	}

	private var header: some View {
		HStack(alignment: .firstTextBaseline, spacing: KKSpacingMD) {
			Image(systemName: "sparkles")
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(Color.kkAccent)
			Text("\u{201C}\(batch.instruction)\u{201D}")
				.font(.system(size: 12, weight: .medium))
				.foregroundStyle(Color.kkAccent)
				.italic()
				.lineLimit(1)
				.truncationMode(.tail)
			Spacer()
			Text("AI Transform Preview")
				.font(.title3)
				.foregroundStyle(.secondary)
				.padding(.horizontal, KKPaddingSM)
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
		HStack(alignment: .top, spacing: KKSpacingLG) {
			Toggle(isOn: $item.include) { EmptyView() }
				.toggleStyle(.checkbox)
				.tint(Color.kkClipColor(isCompound: item.isCompound))
				.disabled(item.alignedWords == nil)
				.padding(.top, 2)
			VStack(alignment: .leading, spacing: KKSpacingXS) {
				if let result = item.resultText {
					let diff = AIWordDiff.diff(original: item.originalText, result: result)
					diff.originalAttributed
						.font(.system(size: 11))
						.textSelection(.enabled)
					diff.resultAttributed
						.font(.system(size: 11))
						.textSelection(.enabled)
				} else {
					Text(item.originalText)
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
				}
				if item.resultText == nil {
					if case .failed(let msg) = item.status {
						Text(msg)
							.font(.system(size: 11))
							.foregroundStyle(Color.kkError)
					} else if isRunning {
						Text("Working\u{2026}")
							.font(.system(size: 11))
							.foregroundStyle(.tertiary)
					}
				}
			}
			Spacer(minLength: 6)
			if let result = item.resultText {
				DiffCountsBadge(
					counts: AIWordDiff.counts(original: item.originalText, result: result))
			}
			status
		}
		.padding(.vertical, KKPaddingSM)
	}

	@ViewBuilder
	private var status: some View {
		switch item.status {
		case .pending:
			ProgressView().controlSize(.small)
		case .ready:
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 11))
				.foregroundStyle(Color.kkSuccess)
		case .failed:
			Image(systemName: "xmark.circle.fill")
				.font(.system(size: 11))
				.foregroundStyle(Color.kkError)
		}
	}
}

private struct DiffCountsBadge: View {
	let counts: (added: Int, removed: Int)

	var body: some View {
		HStack(spacing: KKSpacingXS) {
			if counts.added > 0 {
				Text("+\(counts.added)")
					.foregroundStyle(Color.kkSuccess)
			}
			if counts.removed > 0 {
				Text("-\(counts.removed)")
					.foregroundStyle(Color.kkError)
			}
		}
		.font(.system(size: 10, weight: .semibold).monospacedDigit())
	}
}
