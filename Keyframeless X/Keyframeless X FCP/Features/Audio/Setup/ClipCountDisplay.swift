/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct ClipCountDisplay: View {
	let selectedCount: Int
	let totalCount: Int
	var emptyLabel: String = "No Clips Found"
	var selectedLabel: String = "Clips Selected"

	var body: some View {
		HStack(alignment: .lastTextBaseline, spacing: KKSpacingLG) {
			if totalCount == 0 {
				Text(emptyLabel)
					.font(.title)
					.foregroundStyle(.secondary)
			} else {
				Text("\(selectedCount)")
					.foregroundStyle(Color.kkAccent)
					.font(.title)
				Text(selectedLabel)
					.font(.title)
				Text("\(totalCount) total")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.italic()
			}
			Spacer()
		}
	}
}
