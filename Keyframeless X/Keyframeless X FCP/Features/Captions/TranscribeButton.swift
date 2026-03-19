/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import SwiftUI

struct TranscribeButton: View {
	let disabled: Bool
	var action: () -> Void = {}

	var body: some View {
		PrimaryButton(
			label: "Transcribe", systemImage: "sparkles.rectangle.stack.fill", disabled: disabled,
			action: action)
	}
}
