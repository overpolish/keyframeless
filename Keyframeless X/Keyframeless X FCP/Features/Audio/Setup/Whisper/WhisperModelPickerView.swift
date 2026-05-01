/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct WhisperModelPickerView: View {
	@ObservedObject var manager: WhisperModelManager

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			HStack(alignment: .firstTextBaseline) {
				Text("Model")
					.font(.title3)
					.foregroundStyle(.secondary)
				Spacer()
				HelperText("Recommended is based on hardware")
			}
			.frame(height: 20)

			ScrollShadowView {
				LazyVStack(alignment: .leading, spacing: KKSpacingXS) {
					let groups = ModelGroup.grouped(WhisperModelManager.models)
					ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
						if index > 0 {
							ModelGroupHeader(title: group.title)
								.padding(.top, KKSpacingMD)
						} else {
							ModelGroupHeader(title: group.title)
						}
						ForEach(group.models) { model in
							WhisperModelRow(model: model, manager: manager)
						}
					}
					if !WhisperModelManager.isAppleSilicon {
						IntelModelNote()
					}
				}
				.padding(KKPaddingMD)
			}
			.kkPanel()
			.frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
		}
	}
}

private struct WhisperModelRow: View {
	let model: WhisperModelManager.ModelInfo
	@ObservedObject var manager: WhisperModelManager

	var body: some View {
		let isDownloaded = manager.downloadedModels.contains(model.id)
		let isDownloading = manager.downloadingModel == model.id
		let isSelected = manager.selectedModel == model.id
		let accent = Color.kkAccent

		HStack(spacing: KKSpacingLG) {
			Circle()
				.fill(isSelected ? accent : Color.secondary.opacity(0.3))
				.frame(width: 6, height: 6)

			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: KKSpacingLG) {
					Text(model.displayName)
						.font(.system(size: 12, weight: isSelected ? .medium : .regular))
						.foregroundStyle(isDownloaded ? .primary : .secondary)
					if model.id == WhisperModelManager.recommendedModelId {
						InfoBadge(
							label: "Recommended",
							systemImage: "desktopcomputer.and.macbook",
							color: .green
						)
					}
					Text(model.sizeDescription)
						.font(.system(size: 10))
						.foregroundStyle(.tertiary)
				}
				Text(model.hint)
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
			}

			Spacer()

			if isDownloading {
				ModelDownloadProgress(
					progress: manager.downloadProgress,
					accent: accent,
					indeterminate: model.engine == .parakeet
				)
			} else if !isDownloaded {
				ModelDownloadButton(accent: accent, disabled: manager.downloadingModel != nil) {
					Task { await manager.download(model.id) }
				}
			}
		}
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKSpacingMD)
		.kkSelectableBackground(isSelected)
		.contentShape(Rectangle())
		.onTapGesture {
			if isDownloaded { manager.selectedModel = model.id }
		}
		.contextMenu {
			if isDownloaded {
				Button(role: .destructive) {
					manager.uninstall(model.id)
				} label: {
					Label("Uninstall", systemImage: "trash")
				}
			}
		}
	}
}

private struct ModelGroup {
	let title: String
	let models: [WhisperModelManager.ModelInfo]

	static func grouped(_ all: [WhisperModelManager.ModelInfo]) -> [ModelGroup] {
		var groups: [ModelGroup] = []
		var current: (title: String, models: [WhisperModelManager.ModelInfo])?
		for model in all {
			let title = title(for: model.engine)
			if current?.title == title {
				current?.models.append(model)
			} else {
				if let c = current { groups.append(ModelGroup(title: c.title, models: c.models)) }
				current = (title, [model])
			}
		}
		if let c = current { groups.append(ModelGroup(title: c.title, models: c.models)) }
		return groups
	}

	private static func title(for engine: WhisperModelManager.Engine) -> String {
		switch engine {
		case .whisperKit, .whisperCpp: return "Whisper"
		case .parakeet: return "Parakeet"
		}
	}
}

private struct ModelGroupHeader: View {
	let title: String

	var body: some View {
		Text(title)
			.font(.system(size: 10, weight: .semibold))
			.foregroundStyle(.tertiary)
			.padding(.horizontal, KKPaddingLG)
			.padding(.bottom, 2)
	}
}

private struct IntelModelNote: View {
	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Image(systemName: "apple.logo")
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
			Text("Larger models are available on Apple Silicon Macs")
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
		}
		.padding(.top, KKSpacingSM)
	}
}

private struct ModelDownloadProgress: View {
	let progress: Double
	let accent: Color
	var indeterminate: Bool = false

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			if indeterminate {
				ProgressView()
					.progressViewStyle(.linear)
					.tint(accent)
					.frame(width: 60)
			} else {
				ProgressView(value: progress)
					.progressViewStyle(.linear)
					.tint(accent)
					.frame(width: 60)
				Text("\(Int(progress * 100))%")
					.font(.system(size: 9))
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
		}
	}
}

private struct ModelDownloadButton: View {
	let accent: Color
	let disabled: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 3) {
				Image(systemName: "arrow.down.circle")
				Text("Download")
			}
			.font(.system(size: 10))
			.foregroundStyle(accent)
		}
		.buttonStyle(.plain)
		.disabled(disabled)
	}
}
