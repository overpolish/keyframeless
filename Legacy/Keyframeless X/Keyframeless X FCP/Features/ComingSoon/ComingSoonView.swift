/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

struct ComingSoonView: View {
	var body: some View {
		ContentUnavailableView("Coming Soon", systemImage: "sparkles")
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
