/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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
