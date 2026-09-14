/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct TranscribedClipGroup {
	let clipIndex: Int
	let clipName: String
	let isCompound: Bool
	let sentences: [AudioEditRow]
}

struct TranscribedFlatRow: Identifiable {
	enum Kind {
		case header
		case sentence(AudioEditRow)
	}
	let group: TranscribedClipGroup
	let kind: Kind

	var id: Int {
		switch kind {
		case .header: return -group.clipIndex - 1
		case .sentence(let row): return row.id
		}
	}
}
