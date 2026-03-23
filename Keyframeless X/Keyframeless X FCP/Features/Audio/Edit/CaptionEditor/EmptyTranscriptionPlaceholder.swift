/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct EmptyTranscriptionPlaceholder: View {
	var body: some View {
		VStack(spacing: KKSpacingSM) {
			Image(systemName: "waveform.slash")
				.font(.title3)
				.foregroundStyle(.tertiary)
			Text("No transcribed clips")
				.font(.subheadline)
				.foregroundStyle(.tertiary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.padding(KKPaddingLG)
	}
}
