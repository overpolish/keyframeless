/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import SwiftUI

struct ComingSoonView: View {
	var body: some View {
		ContentUnavailableView("Coming Soon", systemImage: "sparkles")
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
