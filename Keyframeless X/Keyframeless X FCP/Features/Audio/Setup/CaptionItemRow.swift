/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct CaptionItemRow: View {
	let name: String
	let isHidden: Bool
	let clips: [FCPXMLParser.AudioClip]
	@Binding var selectedClips: Set<Int>

	var body: some View {
		HStack {
			Text(name)
				.font(.title2)
				.lineLimit(1)
				.opacity(isHidden ? 0 : 1)
			Spacer()
		}
	}
}
