/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Combine
import CoreMedia
import Foundation
import ProExtensionHost

class CaptionsModel: ObservableObject {

	@Published var timelineDuration: String = "—"

	func updateFromTimeline() {
		guard let timeline = FCPHost.shared.timeline else {
			timelineDuration = "—"
			return
		}
		let seconds = CMTimeGetSeconds(timeline.sequenceTimeRange.duration)
		if seconds.isNaN || seconds < 0 {
			timelineDuration = "—"
		} else {
			timelineDuration = String(format: "%.2fs", seconds)
		}
	}

	func insertTitle() {
		let sequence = FCPHost.shared.timeline?.activeSequence
		let frameDuration = sequence?.frameDuration ?? CMTime(value: 1, timescale: 30)
		let words = "hello from keyframeless x".split(separator: " ").map(String.init)
		let fcpxml = FCPXMLBuilder.titlesXML(words: words, frameDuration: frameDuration)
		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("keyframeless_title.fcpxml")
		try? fcpxml.write(to: tmpURL, atomically: true, encoding: .utf8)
		NSWorkspace.shared.open(tmpURL)
	}

}
