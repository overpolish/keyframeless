/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct AudioExportOptionsView: View {
	@ObservedObject var model: AudioModel

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			ProjectSettingsHeader(model: model)
			CaptionTypeSelector(model: model).padding(.bottom, KKPaddingMD)
			CaptionStyleControls(model: model)
		}
		.onAppear {
			if !model.exportSettingsInitialized {
				let format = model.projectFormat ?? .default
				model.exportWidth = "\(format.width)"
				model.exportHeight = "\(format.height)"
				model.exportFramerate = Framerate.from(frameDuration: format.frameDuration)
				model.exportSettingsInitialized = true
			}
		}
	}
}

struct CaptionTypeSelector: View {
	@ObservedObject var model: AudioModel

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingMD) {
			HStack(spacing: KKSpacingSM) {
				Text("Caption Type")
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer()
				PillToggle(
					selection: $model.captionImportType,
					options: [
						(label: String(localized: "Title"), value: CaptionImportType.title),
						(label: String(localized: "Caption"), value: CaptionImportType.caption),
					]
				)
			}
			if model.captionImportType == .caption {
				HStack(spacing: KKSpacingSM) {
					Text("Caption Format")
						.font(.caption)
						.foregroundStyle(.secondary)
					Spacer()
					PillToggle(
						selection: $model.captionFormat,
						options: CaptionFormat.allCases.map { (label: $0.label, value: $0) }
					)
				}
			}
		}
	}
}

struct AudioExportOptionsSidebar: View {
	@ObservedObject var model: AudioModel
	let rows: [AudioEditRow]
	let srtHasOverlaps: Bool

	@State private var hasAccessibility = AXIsProcessTrusted()
	@State private var accessibilityTimer: Timer?

	private var hasTranscribedSelection: Bool {
		let selected = model.editSelectedClips ?? Set(model.audioClips.indices)
		return rows.contains { !$0.isHeader && $0.isTranscribed && selected.contains($0.clipIndex) }
	}

	private var captionMode: Bool { model.captionImportType == .caption }

	private var dragEnabled: Bool {
		hasTranscribedSelection && !srtHasOverlaps
	}

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingLG) {
			Text("Export Settings")
				.font(.title3)
				.foregroundStyle(.secondary)
			VStack(spacing: KKSpacingLG) {
				AudioExportOptionsView(model: model)
				Spacer()
				HStack(spacing: KKSpacingLG) {
					if !captionMode {
						FCPDragZoneView(
							nativeDataProvider: { model.buildNativePasteboardData(from: rows) },
							onDragStateChanged: { model.isDraggingToFCP = $0 }
						)
						.allowsHitTesting(dragEnabled)
						.opacity(dragEnabled ? 1 : 0.4)
					}
					PrimaryButton(
						label: String(localized: "Paste to FCP"),
						systemImage: "doc.on.clipboard",
						disabled: !hasTranscribedSelection || !hasAccessibility,
						fontSize: 11
					) {
						if let data = model.buildNativePasteboardData(from: rows) {
							FCPDragSourceView.pasteToTimeline(data: data)
						}
					}
					.onAppear {
						hasAccessibility = AXIsProcessTrusted()
						guard !hasAccessibility else { return }
						accessibilityTimer = Timer.scheduledTimer(
							withTimeInterval: 2, repeats: true
						) { _ in
							let granted = AXIsProcessTrusted()
							DispatchQueue.main.async {
								hasAccessibility = granted
								if granted { accessibilityTimer?.invalidate() }
							}
						}
					}
					.onDisappear { accessibilityTimer?.invalidate() }
					FCPXMLImportButton(
						action: { model.insertTitle(rows: rows) }
					)
					.allowsHitTesting(hasTranscribedSelection)
					.opacity(hasTranscribedSelection ? 1 : 0.4)
					SRTExportButton(
						hasOverlaps: srtHasOverlaps,
						action: { model.exportSRT(from: rows) }
					)
					.allowsHitTesting(hasTranscribedSelection)
					.opacity(hasTranscribedSelection ? 1 : 0.4)
				}
				.fixedSize(horizontal: false, vertical: true)
				.overlay(alignment: .top) {
					if !hasAccessibility {
						Text(
							"Paste requires Accessibility access. [Open Settings](x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility)"
						)
						.font(.system(size: 10, weight: .light))
						.foregroundStyle(.secondary)
						.environment(
							\.openURL,
							OpenURLAction { url in
								NSWorkspace.shared.open(url)
								return .handled
							}
						)
						.offset(y: -KKSpacingXL - KKSpacingSM)
					} else if hasTranscribedSelection {
						if model.captionImportType == .caption {
							HelperText(
								String(
									localized:
										"When pasting you will need to enable the role in FCP's Timeline Index"
								),
								systemImage: "exclamationmark.triangle"
							)
							.offset(y: -KKSpacingXL - KKSpacingSM)
						} else {
							HelperText(
								srtHasOverlaps
									? String(localized: "Use paste for overlapping clips")
									: String(localized: "Drag for single clip, paste for multiple"),
								systemImage: "info.circle"
							)
							.offset(y: -KKSpacingXL - KKSpacingSM)
						}
					}
				}
			}
			.padding(KKPaddingXL)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.kkPanel()
		}
	}
}
