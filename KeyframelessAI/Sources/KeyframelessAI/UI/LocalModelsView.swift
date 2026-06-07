/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

/// Config-tab view for the Local provider: download, select and manage the
/// on-device models. Mirrors Steno's model picker (selection dot, name,
/// Recommended badge, size, blurb, download/progress) but in plain SwiftUI -
/// this package has no KeyframelessKit dependency.
struct LocalModelsView: View {
	@StateObject private var store = LocalModelStore.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline) {
				Text(AILoc("On-device models"))
					.font(.system(size: 12, weight: .medium))
					.foregroundStyle(Color.aiSecondaryText)
				Spacer()
				Text(AILoc("Recommended is based on your Mac"))
					.font(.system(size: 9))
					.foregroundStyle(Color.aiTertiaryText)
			}

			VStack(alignment: .leading, spacing: 2) {
				ForEach(LocalModelCatalog.models) { model in
					LocalModelRow(model: model, store: store)
				}
			}

			if let err = store.lastError {
				Text(err)
					.font(.system(size: 9))
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
					.textSelection(.enabled)
			}

			Text(AILoc("Runs entirely on your Mac."))
				.font(.system(size: 9))
				.foregroundStyle(Color.aiTertiaryText)
				.fixedSize(horizontal: false, vertical: true)
		}
		.onAppear { store.refreshDownloaded() }
	}
}

private struct LocalModelRow: View {
	let model: LocalAIModel
	@ObservedObject var store: LocalModelStore

	var body: some View {
		let isDownloaded = store.downloadedModels.contains(model.id)
		let isDownloading = store.downloadingModel == model.id
		let isSelected = store.selectedModelID == model.id
		let accent = Color.accentColor

		HStack(spacing: 10) {
			Circle()
				.fill(isSelected ? accent : Color.secondary.opacity(0.3))
				.frame(width: 6, height: 6)

			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 6) {
					Text(model.displayName)
						.font(.system(size: 12, weight: isSelected ? .medium : .regular))
						.foregroundStyle(isDownloaded ? Color.primary : Color.aiSecondaryText)
					if model.id == LocalModelCatalog.recommendedModelID {
						AIPillBadge(
							label: AILoc("Recommended"),
							systemImage: "desktopcomputer", color: .green)
					}
					Text(model.sizeDescription)
						.font(.system(size: 10))
						.foregroundStyle(Color.aiTertiaryText)
				}
				Text(model.blurb)
					.font(.system(size: 10))
					.foregroundStyle(Color.aiSecondaryText)
					.fixedSize(horizontal: false, vertical: true)
			}

			Spacer(minLength: 8)

			if isDownloading {
				DownloadProgress(progress: store.downloadProgress, accent: accent) {
					store.cancelDownload()
				}
			} else if !isDownloaded {
				DownloadButton(accent: accent, disabled: store.downloadingModel != nil) {
					Task { await store.download(model.id) }
				}
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 7)
		.background {
			RoundedRectangle(cornerRadius: 6)
				.fill(isSelected ? accent.opacity(0.10) : Color.clear)
		}
		.contentShape(Rectangle())
		.onTapGesture {
			if isDownloaded { store.select(model.id) }
		}
		.contextMenu {
			if isDownloaded {
				Button(role: .destructive) {
					store.uninstall(model.id)
				} label: {
					Label(AILoc("Uninstall"), systemImage: "trash")
				}
			}
		}
	}
}

private struct DownloadProgress: View {
	let progress: Double
	let accent: Color
	let onCancel: () -> Void

	var body: some View {
		HStack(spacing: 5) {
			ProgressView(value: progress)
				.progressViewStyle(.linear)
				.tint(accent)
				.frame(width: 56)
			Text("\(Int(progress * 100))%")
				.font(.system(size: 9))
				.foregroundStyle(Color.aiSecondaryText)
				.monospacedDigit()
			Button(action: onCancel) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 11))
					.foregroundStyle(Color.aiTertiaryText)
			}
			.buttonStyle(.plain)
		}
	}
}

private struct DownloadButton: View {
	let accent: Color
	let disabled: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 3) {
				Image(systemName: "arrow.down.circle")
				Text(AILoc("Download"))
			}
			.font(.system(size: 10))
			.foregroundStyle(disabled ? Color.secondary : accent)
		}
		.buttonStyle(.plain)
		.disabled(disabled)
	}
}
