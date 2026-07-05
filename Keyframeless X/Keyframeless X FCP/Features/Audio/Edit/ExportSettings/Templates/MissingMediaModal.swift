/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct MissingMediaModal: View {
	let info: MissingMediaInfo
	let onImportWithoutImage: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		ModalContainer(width: 360, onDismiss: onDismiss) {
			VStack(alignment: .leading, spacing: KKSpacingSM) {
				HStack(spacing: KKSpacingMD) {
					Text("Incomplete Template")
						.font(.title3).foregroundStyle(.primary)
					Spacer()
					InfoBadge(
						label: String(localized: "Missing media"),
						systemImage: "exclamationmark.triangle.fill", color: .kkError)
				}
				Text(
					"\"\(info.templateName)\" references media that wasn't included, so it can't be used as-is. Ask the author to re-export it as a self-contained template, or import it without the missing image."
				)
				.font(.system(size: 11)).foregroundStyle(.secondary)
				.padding(.vertical, KKPaddingLG)
				.fixedSize(horizontal: false, vertical: true)
			}
			if !info.missing.isEmpty {
				VStack(alignment: .leading, spacing: KKSpacingXS) {
					ForEach(info.missing, id: \.self) { path in
						HStack(spacing: KKSpacingSM) {
							Image(systemName: "photo.badge.exclamationmark")
								.foregroundStyle(Color.kkError)
							Text(path).font(.system(size: 11)).foregroundStyle(.primary)
								.lineLimit(1).truncationMode(.middle)
						}
					}
				}
				.padding(KKPaddingMD)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Color.kkError.opacity(0.08))
				.clipShape(RoundedRectangle(cornerRadius: KKRadiusSM))
			}
			HStack {
				Button("Cancel") { onDismiss() }
					.buttonStyle(.plain).foregroundStyle(.secondary)
				Spacer()
				Button("Import Without Image") { onImportWithoutImage() }
					.buttonStyle(.plain).foregroundStyle(Color.kkAccent)
			}
		}
	}
}
