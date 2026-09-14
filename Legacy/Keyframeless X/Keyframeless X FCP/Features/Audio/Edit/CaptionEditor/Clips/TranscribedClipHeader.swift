/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscribedClipHeader: View {
	let clipName: String
	let clipIndex: Int
	let isCompound: Bool
	var containsProfanity: Bool = false
	var isFromSRT: Bool = false
	var isProjectWide: Bool = false
	var onDeleteSRT: (() -> Void)? = nil
	var onImportSRT: (() -> Void)? = nil
	var onImportSRTFromURL: ((URL) -> Void)? = nil
	@Binding var selectedClips: Set<Int>

	@State private var isDropTargeted = false
	@State private var showSRTMenu = false

	private var clipColor: Color { .kkClipColor(isCompound: isCompound) }

	var body: some View {
		HStack(spacing: KKSpacingLG) {
			Toggle(
				isOn: Binding(
					get: { selectedClips.contains(clipIndex) },
					set: { isOn in
						if isOn {
							selectedClips.insert(clipIndex)
						} else {
							selectedClips.remove(clipIndex)
						}
					}
				)
			) {
				Text(clipName)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(isProjectWide ? Color.kkAccent : .secondary)
			}
			.toggleStyle(.checkbox)
			.tint(isProjectWide ? Color.kkAccent : clipColor)
			Spacer()
			if !isFromSRT, let onImportSRT {
				Button {
					onImportSRT()
				} label: {
					Text("Import SRT")
						.font(.system(size: 11))
				}
				.buttonStyle(.plain)
				.foregroundStyle(.secondary)
			}
			if isFromSRT {
				Button {
					showSRTMenu = true
				} label: {
					InfoBadge(label: "SRT", systemImage: "text.quote", color: Color.kkWarning)
				}
				.buttonStyle(.plain)
				.popover(isPresented: $showSRTMenu, arrowEdge: .top) {
					VStack(alignment: .leading, spacing: KKSpacingXS) {
						if let onImportSRT {
							Button {
								showSRTMenu = false
								onImportSRT()
							} label: {
								Label("Replace SRT", systemImage: "arrow.triangle.2.circlepath")
									.frame(maxWidth: .infinity, alignment: .leading)
							}
							.buttonStyle(.plain)
							.padding(.horizontal, KKPaddingMD)
							.padding(.vertical, KKPaddingSM)
						}
						if let onDeleteSRT {
							Button {
								showSRTMenu = false
								onDeleteSRT()
							} label: {
								Label("Delete SRT", systemImage: "trash")
									.frame(maxWidth: .infinity, alignment: .leading)
									.foregroundStyle(Color.kkError)
							}
							.buttonStyle(.plain)
							.padding(.horizontal, KKPaddingMD)
							.padding(.vertical, KKPaddingSM)
						}
					}
					.padding(.vertical, KKPaddingSM)
					.frame(width: 180)
					.background(PopoverBackgroundClearer())
				}
			}
			if containsProfanity {
				InfoBadge(
					label: String(localized: "Profanity"),
					systemImage:
						"exclamationmark.bubble.fill",
					color: Color.kkError
				)
			}
		}
		.contentShape(Rectangle())
		.background(
			RoundedRectangle(cornerRadius: CGFloat(KKRadiusSM))
				.fill(Color.kkAccent.opacity(isDropTargeted ? 0.12 : 0))
		)
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			guard let onImportSRTFromURL else { return false }
			for provider in providers {
				provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
					guard let data = item as? Data,
						let url = URL(dataRepresentation: data, relativeTo: nil),
						url.pathExtension.lowercased() == "srt"
					else { return }
					DispatchQueue.main.async { onImportSRTFromURL(url) }
				}
			}
			return true
		}
	}
}
