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

			if KKAIEngine.showInstallNotice {
				KKAIEngineNotice()
			}

			VStack(alignment: .leading, spacing: 2) {
				ForEach(LocalModelCatalog.models) { model in
					LocalModelRow(model: model, store: store)
				}
				if !store.customModels.isEmpty {
					HStack(alignment: .firstTextBaseline) {
						Text(AILoc("Your models"))
							.font(.system(size: 10, weight: .semibold))
							.foregroundStyle(Color.aiSecondaryText)
						Spacer()
						Text(AILoc("Found in your HuggingFace cache"))
							.font(.system(size: 9))
							.foregroundStyle(Color.aiTertiaryText)
					}
					.padding(.top, 6)
					.padding(.horizontal, 8)
					ForEach(store.customModels) { model in
						CustomModelRow(model: model, store: store)
					}
				}
			}
			.opacity(KKAIEngine.showInstallNotice ? 0.5 : 1)

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
		.onAppear { store.startHelperSync() }
		.onDisappear { store.stopHelperSync() }
	}
}

/// Shown when the shared local-inference engine isn't installed: local models can be
/// browsed but need the one-time Kai install before they'll run.
private struct KKAIEngineNotice: View {
	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "shippingbox.fill")
				.font(.system(size: 12))
			VStack(alignment: .leading, spacing: 1) {
				Text(AILoc("Install Kai to run local models"))
					.font(.system(size: 11, weight: .medium))
					.fixedSize(horizontal: false, vertical: true)
				Text(
					AILoc(
						"On-device models run in a small engine you install once - shared by every Keyframeless plugin. Remote (BYOK) works without it."
					)
				)
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
		}
		.foregroundStyle(Color.accentColor)
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(Color.accentColor.opacity(0.1))
				.overlay(
					RoundedRectangle(cornerRadius: 6)
						.strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
				)
		)
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
				Text(model.displayName)
					.font(.system(size: 12, weight: isSelected ? .medium : .regular))
					.foregroundStyle(isDownloaded ? Color.primary : Color.aiSecondaryText)
					.lineLimit(1)
					.truncationMode(.tail)
				Text(model.blurb)
					.font(.system(size: 10))
					.foregroundStyle(Color.aiSecondaryText)
					.lineLimit(1)
					.truncationMode(.tail)
			}
			.layoutPriority(1)

			Spacer(minLength: 8)

			if isDownloading {
				// Downloading: progress ONLY. The fixed-size badges + the progress
				// bar together overflow the row and collapse the (flexible) title,
				// so we drop the badges here - the title keeps its space.
				DownloadProgress(progress: store.downloadProgress, accent: accent) {
					store.cancelDownload()
				}
			} else {
				// Right-aligned badges, STACKED: "Recommended" on its own row above
				// the size+RAM row. Three pills side-by-side are too wide and
				// truncate the title/blurb; stacking halves the right-column width.
				// Size + RAM are neutral (gray) badges (the gray matches the guide's
				// "completed" chip); the green "Recommended" only shows on the
				// best-fit model. Distinct icons disambiguate disk vs memory.
				VStack(alignment: .trailing, spacing: 3) {
					if model.id == LocalModelCatalog.recommendedModelID {
						AIPillBadge(
							label: AILoc("Recommended"),
							systemImage: "desktopcomputer", color: .green)
					}
					HStack(spacing: 4) {
						AIPillBadge(
							label: model.sizeDescription,
							systemImage: "internaldrive", color: .secondary)
						AIPillBadge(
							label: "\(model.minRAMGB) GB",
							systemImage: "memorychip", color: .secondary)
					}
				}
				if !isDownloaded {
					DownloadButton(accent: accent, disabled: store.downloadingModel != nil) {
						Task { await store.download(model.id) }
					}
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

/// A model adopted from the user's own HuggingFace cache: selectable, sized,
/// removable - never downloadable, never "Recommended" (there is no RAM floor
/// to rank it by; the user chose to have it).
private struct CustomModelRow: View {
	let model: LocalModelStore.CustomLocalModel
	@ObservedObject var store: LocalModelStore

	var body: some View {
		let isSelected = store.selectedModelID == model.id
		let accent = Color.accentColor
		HStack(spacing: 10) {
			Circle()
				.fill(isSelected ? accent : Color.secondary.opacity(0.3))
				.frame(width: 6, height: 6)
			VStack(alignment: .leading, spacing: 1) {
				Text(model.displayName)
					.font(.system(size: 12, weight: isSelected ? .medium : .regular))
					.lineLimit(1)
					.truncationMode(.tail)
				Text(model.repoID)
					.font(.system(size: 10))
					.foregroundStyle(Color.aiSecondaryText)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.layoutPriority(1)
			Spacer(minLength: 8)
			if !model.sizeDescription.isEmpty {
				AIPillBadge(
					label: model.sizeDescription,
					systemImage: "internaldrive", color: .secondary)
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 7)
		.background {
			RoundedRectangle(cornerRadius: 6)
				.fill(isSelected ? accent.opacity(0.10) : Color.clear)
		}
		.contentShape(Rectangle())
		.onTapGesture { store.select(model.id) }
		.contextMenu {
			Button(role: .destructive) {
				store.uninstall(model.id)
			} label: {
				Label(AILoc("Remove from Kai"), systemImage: "trash")
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
			// The poll caps at 0.99 while HuggingFace verifies + commits the
			// downloaded blobs (a slow tail on a multi-GB model). During that,
			// swap to an INDETERMINATE bar + "Finalizing" so it animates instead
			// of a determinate bar sitting frozen at 99%.
			Group {
				if progress >= 0.99 {
					ProgressView()
				} else {
					ProgressView(value: progress)
				}
			}
			.progressViewStyle(.linear)
			.tint(accent)
			.frame(width: 56)
			Text(progress >= 0.99 ? AILoc("Finalizing") : "\(Int(progress * 100))%")
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
					.lineLimit(1)
			}
			.font(.system(size: 10))
			.foregroundStyle(disabled ? Color.secondary : accent)
			.fixedSize()
		}
		.buttonStyle(.plain)
		.disabled(disabled)
	}
}
