/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

struct ProcessButton: View {
	let disabled: Bool
	var action: () -> Void = {}

	var body: some View {
		PrimaryButton(
			label: "Process", systemImage: "sparkles.rectangle.stack.fill", disabled: disabled,
			action: action)
	}
}
