/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct TimelineFooterMessages: View {
	let clips: [FCPXMLParser.AudioClip]

	private var unhandledSummary: String? {
		var union = Set<String>()
		for clip in clips {
			if let adj = clip.unhandledAdjustments { union.formUnion(adj) }
		}
		guard !union.isEmpty else { return nil }
		let names = union.sorted().map(Self.displayName(for:)).joined(separator: ", ")
		return String(localized: "Not applied in captions: \(names)")
	}

	nonisolated private static func displayName(for adjustment: String) -> String {
		switch adjustment {
		case "adjust-voiceIsolation": return "Voice Isolation"
		case "adjust-loudness": return "Loudness"
		case "adjust-noiseReduction": return "Noise Reduction"
		case "adjust-humReduction": return "Hum Reduction"
		case "adjust-matchEQ": return "Match EQ"
		default: return adjustment
		}
	}

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Group {
				if let summary = unhandledSummary {
					HelperText(summary, systemImage: "info.circle", warning: true)
				} else {
					HelperText(" ", systemImage: "info.circle")
						.hidden()
				}
			}
			Spacer()
			HelperText(
				String(localized: "Click and drag to quickly select/deselect clips"),
				systemImage: "cursorarrow.motionlines"
			)
		}
		.padding(.horizontal, KKPaddingSM)
	}
}
