/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Fixed Motion factory `objectID/channelPath` identifiers for the built-in Subtitle's published
/// params. Single source of truth shared by the model (curation + export in `AudioModel`) and the
/// grouped `SubtitleStylePanel` layout, so the magic strings live in exactly one place.
enum SubtitleParamKey {
	static let animationStyle = "3336692171/2/100"
	static let animateBy = "3336679301/2/100"
	static let font = "3336674848/83"
	static let fontSize = "3336674848/3"
	static let textColor = "3336674848/14/16"
	static let highlight = "3337240802/2/353/113/111"
	static let backgroundColor = "3336678548/2/353/113/111"
	static let opacity = "3336678548/1/200/202"
	static let cornerRadius = "3336678548/2/353/144"
	static let width = "3336678692/2/100"
	static let height = "3336678786/2/100"
	static let xOffset = "3337241478/2/100"
	static let yOffset = "3337241559/2/100"
	static let verticalAlignment = "3336674846/2/373/2"
	static let socialSafe = "3337013104/2/100"
}
