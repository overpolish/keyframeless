/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct WhisperModelPickerView: View {
	@ObservedObject var manager: WhisperModelManager

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			Text("Transcription")
				.font(.title3)
				.foregroundStyle(.secondary)
				.padding(.horizontal, KKPaddingLG)

			HStack(alignment: .top, spacing: KKSpacingLG) {
				VStack(spacing: 2) {
					ForEach(WhisperModelManager.models) { model in
						modelRow(model)
					}
				}
				.padding(KKPaddingMD)
				.background(
					RoundedRectangle(cornerRadius: KKRadiusMD + 4).fill(Color.white.opacity(0.04))
				)
				.overlay(
					RoundedRectangle(cornerRadius: KKRadiusMD + 4)
						.strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
				)
				.frame(maxWidth: .infinity)

				VStack(alignment: .leading) {}
					.frame(maxWidth: .infinity)
			}
		}
	}

	private func modelRow(_ model: WhisperModelManager.ModelInfo) -> some View {
		let isDownloaded = manager.downloadedModels.contains(model.id)
		let isDownloading = manager.downloadingModel == model.id
		let isSelected = manager.selectedModel == model.id
		let accent = Color(nsColor: .accent() ?? .blue)

		return HStack(spacing: KKSpacingLG) {
			Circle()
				.fill(isSelected ? accent : Color.secondary.opacity(0.3))
				.frame(width: 6, height: 6)

			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: KKSpacingLG) {
					Text(model.displayName)
						.font(.system(size: 12, weight: isSelected ? .medium : .regular))
						.foregroundStyle(isDownloaded ? .primary : .secondary)
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
				HStack(spacing: 4) {
					ProgressView(value: manager.downloadProgress)
						.progressViewStyle(.linear)
						.tint(accent)
						.frame(width: 60)
					Text("\(Int(manager.downloadProgress * 100))%")
						.font(.system(size: 9))
						.foregroundStyle(.secondary)
						.monospacedDigit()
				}
			} else if !isDownloaded {
				Button {
					Task { await manager.download(model.id) }
				} label: {
					HStack(spacing: 3) {
						Image(systemName: "arrow.down.circle")
						Text("Download")
					}
					.font(.system(size: 10))
					.foregroundStyle(accent)
				}
				.buttonStyle(.plain)
				.disabled(manager.downloadingModel != nil)
			}
		}
		.padding(.horizontal, KKPaddingLG)
		.padding(.vertical, KKSpacingMD)
		.background(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(isSelected ? accent.opacity(0.12) : Color.clear)
		)
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
